require 'socket'
require 'yaml'
require 'openssl'

class Fluent::LogentriesDynamicOutput < Fluent::Output
  class ConnectionFailure < StandardError; end
  # First, register the plugin. NAME is the name of this plugin
  # and identifies the plugin in the configuration file.
  Fluent::Plugin.register_output('logentries_dynamic', self)

  config_param :cache_size,          :integer, default: 1000
  config_param :cache_ttl,           :integer, default: 60 * 60
  config_param :use_json,            :bool,    :default => true
  config_param :use_ssl,             :bool,    :default => true
  config_param :api_token,           :string
  config_param :logset_name_field,   :string
  config_param :log_name_field,      :string
  config_param :max_retries,         :integer, :default => 3
  config_param :log_set_name_remove, :string, :default => nil

  SSL_HOST    = "data.logentries.com"

  def configure(conf)
    super
    require 'rest-client'
    require 'lru_redux'

    @cache_ttl = :none if @cache_ttl < 0
    @cache = LruRedux::TTL::ThreadSafeCache.new(@cache_size, @cache_ttl)
    @tokens    = nil
    @last_edit = Time.at(0)
    populate_logsets()
  end

  def start
    super
  end

  def shutdown
    super
  end

  def get_request_headers
    {'x-api-key': @api_token,'Content-Type': 'application/json'}
  end

  def populate_logsets
    url = 'https://rest.logentries.com/management/logsets'

    response = RestClient.get(url, headers=get_request_headers())
    logsets = JSON.parse(response)["logsets"]

    logsets.each do |logset|
      puts "Populating Logset #{logset}"
      @cache[logset["name"]] = get_logset(logset) unless @cache.key?(logset["name"])
    end
  end

  # This method is called when an event reaches Fluentd.
  def format(tag, time, record)
    return [tag, record].to_msgpack
  end

  def get_log_by_id(log_id)
    url = "https://rest.logentries.com/management/logs/#{log_id}"
    response = RestClient.get(url, headers=get_request_headers())
    body = JSON.parse(response)["log"]
  end

  def get_log_by_name(logset_id, log_name)
    url = "https://rest.logentries.com/management/logs"
    response = RestClient.get(url, headers=get_request_headers())
    body = JSON.parse(response)["logs"]

    logset_defined = body.select{ |log| !log["logsets_info"].empty?}
    logset_logs = logset_defined.select{ |log| log["logsets_info"].first["id"] == logset_id }
    logset_logs.select{ |log| log["name"] == log_name }.first
  end

  def get_log_token(log_id)
    raw_log = get_raw_log(log_id)
    raw_log["tokens"].first
  end

  def get_logset(raw_logset)
    logset = {}
    logset["logs"] = {}
    logset["id"]   = raw_logset["id"]
    logset["name"] = raw_logset["name"]
    raw_logset["logs_info"].each do |log|
      logset["logs"][log["name"]] = { "id"=> log["id"]}
    end
    logset
  end


  def create_logset(name)
    return @cache[name] if @cache.key? name

    logset = {}
    data = { "logset":
               {
                 "name": name
               }
           }
    url = 'https://rest.logentries.com/management/logsets'

    begin
      response = RestClient.post(url, data.to_json, headers=get_request_headers())
      body = JSON.parse(response)["logset"]
      logset["id"]   = body["id"]
      logset["name"] = body["name"]
      logset["logs"] = {}
      logset
    rescue RestClient::BadRequest => ex
      puts "An error of type #{ex.class} happened, message is #{ex.message}"
      populate_logsets()
      if @cache.key? name
        return @cache[name]
      else
        raise 'Unable to create logset'
      end
    end
  end

  def log_race_created?(logset_id, name)
    sleep rand(0..0.1)

    url = "https://rest.logentries.com/management/logs"
    response = RestClient.get(url, headers=get_request_headers())
    body = JSON.parse(response)["logs"]
    
    logset_defined = body.select{ |log| !log["logsets_info"].empty?}
    logset_logs = logset_defined.select{ |log| log["logsets_info"].first["id"] == logset_id }
    names = logset_logs.map{ |log| log["name"] }
    names.include? name
  end

  def add_log_to_logset(logset, name)
    log = get_log_by_name(logset["id"], name)
    token = log["tokens"].first

    logset["logs"][name] = {"token"=> token, "id"=> log["id"]}
    logset["logs"][name]
  end

  def create_log(logset, name)
    puts "Creating or finding log #{name} in #{logset}"
    if log_race_created?(logset["id"], name)
      return add_log_to_logset(logset, name)
    else
      log = {}
      data = { "log": {
                 "name": name,
                 "source_type": "token",
                 "logsets_info": [
                    {
                      "id": logset["id"]
                    }
                 ]
                }
              }
      url = 'https://rest.logentries.com/management/logs'
      response = RestClient.post(url, data.to_json, headers=get_request_headers())

      body = JSON.parse(response)["log"]
      token = body["tokens"].first

      logset["logs"][name] = {"token"=> token, "id"=> body["id"]}
      logset["logs"][name]
    end
  end

  def log_token_exists?(logset, log_name)
    return false unless logset && log_name
    if logset["logs"].keys().include? log_name
      logset["logs"][log_name].keys().include? "token"
    else
      return false
    end
  end

  def get_or_create_log_token(logset, log_name)
    if log_token_exists?(logset, log_name)
      return logset["logs"][log_name]
    else
      return create_log(logset, log_name)
    end
  end

  def transform_keys(record)
    result = {}
    record.keys.each do |key|
      result[key.to_s] = record[key]
    end
    result
  end

  # Returns the correct token to use for a given tag / records
  def get_token(tag, record)
    conv_record = transform_keys(record)
    if ([@logset_name_field, @log_name_field] - conv_record.keys()).empty?
      log_name = conv_record[@log_name_field]
      log_set_name = conv_record[@logset_name_field]
      log_name.gsub!(@log_set_name_remove,'') if @log_set_name_remove

      if @cache.key? log_set_name
        logset = @cache[log_set_name]
      else
        logset = create_logset(log_set_name)
        @cache[log_set_name] = logset
      end

      return get_or_create_log_token(logset, log_name)["token"]
    else
      return nil
    end
  end

  # NOTE! This method is called by internal thread, not Fluentd's main thread. So IO wait doesn't affect other plugins.
  def process(tag, es)
    es.each do |time, record|
      next unless record.is_a? Hash
      next unless @use_json or record.has_key? "message"

      token = get_token(tag, record)
      puts "Failed token" if token.nil?
      next if token.nil?

      # Clean up the string to avoid blank line in logentries
      message = @use_json ? record.to_json : record["message"].rstrip()
      send_logentries(token, message)
    end
  end

  def send_logentries(token, data)
    retries = 0

    url = "https://webhook.logentries.com/noformat/logs/#{token}"
    response = RestClient.post(url, data, headers={'Content-Type': 'application/json'})
    if response.code != 204
      puts "Got unexpected response code #{response.code}"
      puts "#{response.body}"
    end
  end

end
