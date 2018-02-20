local policy = require('apicast.policy')
local _M = policy.new('Explode the application details as HTTP Headers')

local openssl = require('openssl')
local sha1 = require('sha1')
local cjson = require('cjson')
local http_ng = require("resty.http_ng")
local resty_env = require('resty.env')
local resty_url = require('resty.url')

local function error(status, code, msg)
  ngx.status = status
  ngx.header['Content-Type'] = 'application/json'
  local payload = {
    error = code,
    error_description = msg
  }
  ngx.say(cjson.encode(payload))
  ngx.exit(ngx.HTTP_OK)
end

local field_mapping = {
  id = "X-3scale-App-ID",
  state = "X-3scale-App-State",
  service_id = "X-3scale-Service-ID",
  plan_id = "X-3scale-ApplicationPlan-ID",
  account_id = "X-3scale-Account-ID",
  name = "X-3scale-App-Name"
}

function _M:access(context, host)
  local service = context.service
  if not service then
    ngx.log(ngx.WARN, "Service configuration could not be found.")
    error(ngx.HTTP_INTERNAL_SERVER_ERROR, "server_error", "Configuration error: check logs for details.")
  end

  local auth_user_key = service.credentials.user_key;
  local credentials_location = service.credentials.location;
  local apikey = nil

  if credentials_location == 'headers' then
    apikey = ngx.req.get_headers()[auth_user_key]
  elseif credentials_location == 'query' then
    apikey = args[auth_user_key]
  end

  if not apikey or apikey == '' then
    error(ngx.HTTP_BAD_REQUEST, "invalid_request", "No apikey parameter found in the request.")
  end

  -- Initialize an HTTP client with default options for dealing with the 3scale admin portal
  local threescale_httpc = http_ng.new({
    options = {
      ssl = { verify = resty_env.enabled('OPENSSL_VERIFY') }
    }
  })
  local portal_endpoint = resty_env.get("THREESCALE_PORTAL_ENDPOINT")
  local res, err = threescale_httpc.get(resty_url.join(portal_endpoint, "/admin/api/applications/find.json?" .. ngx.encode_args({ user_key = apikey })), {})
  if not res then
    error(ngx.HTTP_INTERNAL_SERVER_ERROR, "server_error", "Could not get a response from the 3scale API.")
  end
  local json_body = cjson.decode(res.body)
  local app = json_body['application']
  if app then
    for app_field, header in pairs(field_mapping) do
      ngx.req.set_header(header, app[app_field] or '<NONE>')
    end
  end
end

return _M
