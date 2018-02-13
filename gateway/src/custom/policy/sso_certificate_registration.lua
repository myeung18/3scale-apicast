local policy = require('apicast.policy')
local _M = policy.new('SSO Client Certificate Registration')

local error = require('custom.error')
local resty_env = require('resty.env')
local resty_url = require('resty.url')
local cjson = require('cjson')
local http_ng = require("resty.http_ng")

local configuration_loader = require('apicast.configuration_loader')
local remote_configuration = require('apicast.configuration_store').new()
local remote_loader_v2 = require('apicast.configuration_loader.remote_v2')


local function init_config(config)
  local res = {}

  -- Default values
  res.sso_client_id = config.sso_client_id or "admin-cli"

  -- Get other values either from provided config or environment variables
  local envs = { "THREESCALE_PORTAL_ENDPOINT" }
  for i, env in ipairs(envs) do
    local item = string.lower(env)
    local value = config[item] or resty_env.get(env)
    if not value then
      ngx.log(ngx.WARN, "Could not get configuration: ", env)
    else
      res[item] = value
    end
  end

  return res
end


local new = _M.new
function _M.new(config)
  local self = new()
  self.config = init_config(config or {})
  return self
end

function _M:access(context, host)
  if ngx.req.get_method() ~= "POST" then
    error(ngx.HTTP_NOT_ALLOWED, "invalid_request", "Only POST requests are accepted.")
  end

  if ngx.req.get_headers()["Content-Type"] ~= "application/x-www-form-urlencoded" then
    -- HTTP 415 is "Unsupported media"
    error(415, "invalid_request", "Wrong content-type. Must be application/x-www-form-urlencoded.")
  end

  -- Make sure nginx read the post body
  ngx.req.read_body()

  local args, err = ngx.req.get_post_args()
  if not args then
    error(ngx.HTTP_BAD_REQUEST, "invalid_request", "No post parameters found.")
  end

  local host = context.host or ngx.var.host
  if not configuration_loader.configured(context.configuration, host) then
    ngx.log(ngx.WARN, "Configuration outdated, refreshing using lazy loader...")
    local loader = configuration_loader.new('lazy')
    context.configuration = loader.rewrite(context.configuration, host)
  end
  local service = context.configuration:find_by_host(host)
  if not service or #service > 1 then
    ngx.log(ngx.WARN, "Service configuration could not be found : n = ", service and #service)
    error(ngx.HTTP_INTERNAL_SERVER_ERROR, "server_error", "Configuration error: check logs for details.")
  end

  local service = service[1]
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

  if not args['client_id'] or args['client_id'] == '' then
    error(ngx.HTTP_BAD_REQUEST, "invalid_request", "No client_id parameter found in the request.")
  end

  local client_id = args['client_id']

  -- Initialize an HTTP client with default options for dealing with the 3scale admin portal
  local threescale_httpc = http_ng.new({
    options = {
      ssl = { verify = resty_env.enabled('OPENSSL_VERIFY') }
    }
  })

  local res, err = threescale_httpc.get(resty_url.join(self.config.threescale_portal_endpoint, "/admin/api/applications/find.json?" .. ngx.encode_args({ user_key = apikey })), {})
  if not res then
    error(ngx.HTTP_INTERNAL_SERVER_ERROR, "server_error", "Could not get a response from the 3scale API.")
  end

  local json_body = cjson.decode(res.body)
  local apikey_account_id = json_body['application'] and json_body['application']['account_id']

  local res, err = threescale_httpc.get(resty_url.join(self.config.threescale_portal_endpoint, "/admin/api/applications/find.json?" .. ngx.encode_args({ app_id = client_id })), {})
  if not res then
    error(ngx.HTTP_INTERNAL_SERVER_ERROR, "server_error", "Could not get a response from the 3scale API.")
  end

  json_body = cjson.decode(res.body)
  local client_account_id = json_body['application'] and json_body['application']['account_id']
  if client_account_id ~= apikey_account_id then
    error(ngx.HTTP_FORBIDDEN, "server_error", "The apikey and client_id do not belong to the same account.")
  end

  local target_service_id = json_body['application'] and json_body['application']['service_id']
  local target_service = remote_configuration:find_by_id(tostring(target_service_id))
  if not target_service then
    -- Fetch an up-to-date configuration from the 3scale admin portal
    configuration_loader.configure(remote_configuration, remote_loader_v2.call())
    target_service, err = remote_configuration:find_by_id(tostring(target_service_id))
    ngx.log(ngx.WARN, "err = ", err)
  end
  if not target_service or #target_service > 1 then
    ngx.log(ngx.WARN, "Service configuration for service_id = '", target_service_id, "' could not be found : n = ", target_service and #target_service)
    error(ngx.HTTP_INTERNAL_SERVER_ERROR, "server_error", "Configuration error: check logs for details.")
  end

  local oidc_issuer_endpoint = target_service.oidc and target_service.oidc.issuer_endpoint
  local sso_url = resty_url.parse(oidc_issuer_endpoint)

  -- Extract the realm from the oidc_issuer_endpoint
  local path_components = {}
  for component in string.gmatch(sso_url.path, "[^/]+") do
     table.insert(path_components, component)
  end
  local realm = path_components[3]
  ngx.log(ngx.INFO, "Working on SSO realm ", realm)

  local base_url = string.format("%s://%s:%u", sso_url.scheme, sso_url.host, sso_url.port or resty_url.default_port(sso_url.scheme))
  local token_endpoint = resty_url.join(base_url, sso_url.path, "/protocol/openid-connect/token")
  local clients_endpoint = resty_url.join(base_url, "/auth/admin/realms", realm, "/clients")

  -- Initialize an HTTP client with default options for dealing with RH-SSO
  local sso_httpc = http_ng.new({
    options = {
      ssl = { verify = resty_env.enabled('OPENSSL_VERIFY') },
      headers = {
        host = sso_url.host
      }
    }
  })

  res, err = sso_httpc.post(token_endpoint,
    ngx.encode_args({
      client_id = self.config.sso_client_id,
      username = sso_url.user,
      password = sso_url.password,
      grant_type = "password"
    }), {
      headers = {
        ["Content-Type"] = "application/x-www-form-urlencoded"
      }
  })

  if not res or res.status ~= ngx.HTTP_OK then
    error(ngx.HTTP_INTERNAL_SERVER_ERROR, "server_error", "Could not get an access token with admin privileges on RH-SSO.")
  end

  json_body = cjson.decode(res.body)
  local access_token = json_body['access_token']

  -- Re-initialize an HTTP client with default options for dealing with RH-SSO
  sso_httpc = http_ng.new({
    options = {
      ssl_verify = resty_env.enabled('OPENSSL_VERIFY'),
      headers = {
        Authorization = "Bearer " .. access_token,
        host = sso_url.host
      }
    }
  })

  res, err = sso_httpc.get(clients_endpoint .. "?" .. ngx.encode_args({ clientId = client_id }), {})
  if not res or res.status ~= ngx.HTTP_OK then
    ngx.log(ngx.WARN, "Could not retrieve the list of clients in RH-SSO: status = ", res and res.status)
    error(ngx.HTTP_INTERNAL_SERVER_ERROR, "server_error", "Could not retrieve the list of clients in RH-SSO.")
  end

  json_body = cjson.decode(res.body)
  local client_id_rhssoid = json_body[1] and json_body[1]['id']
  if not client_id_rhssoid then
    error(ngx.HTTP_INTERNAL_SERVER_ERROR, "server_error", "Could not find the client in RH-SSO.")
  end

  local jwt_certificates_endpoint = resty_url.join(base_url, "/auth/admin/realms", realm, "/clients/", client_id_rhssoid, "/certificates/jwt.credential")
  local jwt_certificates_upload_endpoint = resty_url.join(jwt_certificates_endpoint, "/upload")

  res, err = sso_httpc.get(jwt_certificates_endpoint, {})
  if not res or res.status ~= ngx.HTTP_OK then
    error(ngx.HTTP_INTERNAL_SERVER_ERROR, "server_error", "Could not check client certificates in RH-SSO.")
  end

  json_body = cjson.decode(res.body)
  local existing_certificate = json_body['certificate']

  if existing_certificate then
    error(ngx.HTTP_FORBIDDEN, "invalid_request", "Already registered.")
  end

  local certificate = ngx.var.ssl_client_raw_cert
  local start, len = string.find(certificate, "[-]+BEGIN CERTIFICATE[-]+")
  start = start + len
  local finish = string.find(certificate, "[-]+END CERTIFICATE[-]+")
  certificate = string.sub(certificate, start, finish-1)

  local raw_certificate = ""
  for i in string.gmatch(certificate, "[a-zA-Z0-9+/=]+") do
    raw_certificate = raw_certificate .. i
  end

  local boundary = string.format("--------------------------%s", ngx.var.request_id)
  local content_type = "multipart/form-data; boundary=" .. boundary

  body = string.format('--%s\r\nContent-Disposition: form-data; name="file"\r\nContent-Type: application/octet-stream\r\n\r\n%s\r\n--%s\r\nContent-Disposition: form-data; name="keystoreFormat"\r\n\r\n%s\r\n--%s--\r\n', boundary, raw_certificate, boundary, "Certificate PEM", boundary)
  res, err = sso_httpc.post(jwt_certificates_upload_endpoint, body, {
    headers = {
      ["Content-Type"] = content_type
    }
  })

  if not res or res.status ~= ngx.HTTP_OK then
    error(ngx.HTTP_INTERNAL_SERVER_ERROR, "invalid_request", "Could not register certificate in RH-SSO.")
  end

  ngx.status = ngx.HTTP_OK
  ngx.header['Content-Type'] = 'application/json'
  ngx.say('{"status": "registered"}')

  ngx.exit(ngx.HTTP_OK)
end

return _M
