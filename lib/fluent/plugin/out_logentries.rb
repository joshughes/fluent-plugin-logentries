require 'socket'
require 'yaml'
require 'openssl'

class Fluent::LogentriesOutput < Fluent::BufferedOutput
  class ConnectionFailure < StandardError; end
  # First, register the plugin. NAME is the name of this plugin
  # and identifies the plugin in the configuration file.
  Fluent::Plugin.register_output('logentries', self)

  config_param :cache_size,          :integer, default: 1000
  config_param :cache_ttl,           :integer, default: 60 * 60
  config_param :use_json,            :bool,    :default => false
  config_param :port,                :integer, :default => 443
  config_param :protocol,            :string,  :default => 'tcp'
  config_param :api_token            :string
  config_param :logset_name_field    :string
  config_param :log_name_field       :string
  config_param :max_retries,         :integer, :default => 3

  SSL_HOST    = "data.logentries.com"

  def configure(conf)
    super
    require 'rest-client'
    require 'lru_redux'

    @cache_ttl = :none if @cache_ttl < 0
    @cache = LruRedux::TTL::ThreadSafeCache.new(@cache_size, @cache_ttl)
    @tokens    = nil
    @last_edit = Time.at(0)
  end

  def start
    super
    populate_logsets()
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
      @cache[logset["name"]] = get_logset(logset)
    end
  end

  def client
    @_socket ||=
      context    = OpenSSL::SSL::SSLContext.new
      socket     = TCPSocket.new SSL_HOST, 443
      ssl_client = OpenSSL::SSL::SSLSocket.new socket, context

      ssl_client.connect
  end

  # This method is called when an event reaches Fluentd.
  def format(tag, time, record)
    return [tag, record].to_msgpack
  end

  def get_log(raw_log)
    href = raw_log["links"].find{|link| link["rel"] == "Self"}["href"]
    response = RestClient.get(href, headers=get_request_headers())
    body = JSON.parse(response)["log"]
    token = body["tokens"].first
    {"token": token, "id": body["id"]}
  end

  def get_logset(raw_logset)
    logset = {}
    logset["id"]   = raw_logset["id"]
    logset["name"] = raw_logset["name"]

    raw_logset["logs_info"].each do |log|
      logset["logs"][log["name"]] = get_log(log)
    end
    logset
  end

  def create_logset(name, try=0)
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
      logset
    rescue RestClient::BadRequest
      sleep 0.1
      populate_logsets()
      if @cache.keys().include? name
        return @cache[name]
      elsif try > 3
        raise 'Unable to create logset'
      else
        return create_logset(name, try=try+1)
      end
    end
  end

  def create_log(logset, name, try=0)
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

    begin
      response = RestClient.post(url, data.to_json, headers=get_request_headers())
      body = JSON.parse(response)["log"]
      token = body["tokens"].first
      logset["logs"][name] = {"token": token, "id": body["id"]}
      logset["logs"][name]
    rescue RestClient::BadRequest
      sleep 0.1
      populate_logsets()
      if log_token_exists?(@cache[logset["name"]], name)
        return @cache[logset["name"]][name]
      elsif try > 3
        raise 'Unable to create logset'
      else
        return create_log(logset, name, try=try+1)
      end
    end
  end

  def log_token_exists?(logset, log_name)
    logset["logs"].keys().include? log_name
  end

  def get_or_create_log_token(logset, log_name)
    if log_token_exists?(logset, log_name)
      return logset["logs"][log_name]["token"]
    else
      return create_log(logset, log_name)["token"]
    end
  end

  # Returns the correct token to use for a given tag / records
  def get_token(tag, record)
    if ([@logset_name_field, @log_name_field] - record.keys()).empty?
      return nil
    else
      log_name = record[@log_name_field]
      logset   = @cache[record[@logset_name_field]]

      return get_or_create_log_token(logset, log_name)
    end
  end

  # NOTE! This method is called by internal thread, not Fluentd's main thread. So IO wait doesn't affect other plugins.
  def write(chunk)

    chunk.msgpack_each do |tag, record|
      next unless record.is_a? Hash
      next unless @use_json or record.has_key? "message"

      token = get_token(tag, record)
      next if token.nil?

      # Clean up the string to avoid blank line in logentries
      message = @use_json ? record.to_json : record["message"].rstrip()
      send_logentries(token, message)
    end
  end

  def send_logentries(token, data)
    retries = 0
    begin
      log.debug "Writing data to logentries socket!!!!"
      client.write("#{token} #{data} \n")
      log.debug "Wrote data to logentries socket!!!!"
    rescue Errno::ECONNREFUSED, Errno::ETIMEDOUT, Errno::EPIPE => e
      if retries < @max_retries
        retries += 1
        @_socket = nil
        log.warn "Could not push logs to Logentries, resetting connection and trying again. #{e.message}"
        sleep 5**retries
        retry
      end
      raise ConnectionFailure, "Could not push logs to Logentries after #{retries} retries. #{e.message}"
    rescue Errno::EMSGSIZE
      str_length = data.length
      send_logentries(token, data[0..str_length/2])
      send_logentries(token, data[(str_length/2)+1..str_length])

      log.warn "Message Too Long, re-sending it in two part..."
    end
  end

end
