require 'rest-client'
require 'json'
require 'lru_redux'

@cache = LruRedux::TTL::ThreadSafeCache.new(1000, 60 * 60)

def get_log(raw_log)
  puts "Getting log #{raw_log['name']}"
  href = raw_log["links"].find{|link| link["rel"] == "Self"}["href"]

  response = RestClient.get(href, headers=get_request_headers())
  body = JSON.parse(response)["log"]

  token = body["tokens"].first
  {"token": token, "id": body["id"]}
end

def get_logset(raw_logset)
  logset = {}
  logset["logs"] = {}
  logset["id"]   = raw_logset["id"]
  logset["name"] = raw_logset["name"]

  raw_logset["logs_info"].each do |log|
    logset["logs"][log["name"]] = get_log(log)
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
  rescue RestClient::BadRequest
    populate_logsets()
    if @cache.key? name
      return @cache[name]
    else
      raise 'Unable to create logset'
    end
  end
end

def log_race_created?(logset, name)
  sleep rand(0..0.1)
  url = "https://rest.logentries.com/management/logsets/#{logset['id']}"
  response = RestClient.get(url, headers=get_request_headers())
  body = JSON.parse(response)["logset"]

  body["logs_info"].map{ |log| log["name"]}.include? name
end

def create_log(logset, name)
  if log_token_exists?(logset, name)
    return logset["logs"][name]
  elsif log_race_created?(logset, name)
    populate_logsets()
    if log_token_exists?(@cache[logset["name"]], name)
      return @cache[logset["name"]]["logs"][name]
    else
      raise 'Unable to create log'
    end
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

    logset["logs"][name] = {"token": token, "id": body["id"]}
    logset["logs"][name]
  end
end

def log_token_exists?(logset, log_name)
  puts "Checking if #{log_name} in"
  puts logset
  logset["logs"].keys().include? log_name
end

def get_or_create_log_token(logset, log_name)
  if log_token_exists?(logset, log_name)
    return logset["logs"][log_name]["token"]
  else
    return create_log(logset, log_name)["token"]
  end
end

def get_request_headers
  {'x-api-key': 'b992ccf7-ed9e-46d8-bed0-cf1aa3f2f6a0','Content-Type': 'application/json'}
end

def populate_logsets
  url = 'https://rest.logentries.com/management/logsets'

  response = RestClient.get(url, headers=get_request_headers())
  logsets = JSON.parse(response)["logsets"]

  logsets.each do |logset|
    @cache[logset["name"]] = get_logset(logset)
  end
end

puts "Populating logsets"
populate_logsets()
# puts "Creating Logsets"
foobar = create_logset('foobar')
puts foobar
#
# puts foobar
puts create_log(foobar, 'bazz2')


# logsets.each do |logset|
#   get_logset(logset)
# end



# @cache.getset(container_id) do
#   get_container_metadata(container_id)
# end
