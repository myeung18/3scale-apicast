local policy = require('apicast.policy')
local _M = policy.new('Bind SSL/TLS client certificate authentication with the provided OIDC token')

local resty_env = require('resty.env')
local resty_url = require('resty.url')
local cjson = require('cjson')
local http_ng = require("resty.http_ng")

local configuration_loader = require('apicast.configuration_loader')

local error = require('custom.error')

local function init_config(config)
  local res = {}

  -- Default values
  res.sso_client_id = config.sso_client_id or "admin-cli"

  -- Get other values either from provided config or environment variables
  local envs = { "SSO_OVERRIDE_HOSTNAME" }
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
  local jwt = context.jwt
  if not jwt then
    error(ngx.HTTP_FORBIDDEN, "access_denied", "No JWT token found in the context !")
    return
  end

  -- Extract the client_id from the OpenID Connect
  local client_id = jwt.azp or jwt.aud
  if not client_id then
    error(ngx.HTTP_FORBIDDEN, "access_denied", "Could not find any client_id in the OpenID Connect token.")
    return
  end
  ngx.log(ngx.INFO, "Checking SSL/TLS Client certificate of client ", client_id)

  local service = context.service
  if not service then
    ngx.log(ngx.WARN, "Service configuration could not be found.")
    error(ngx.HTTP_INTERNAL_SERVER_ERROR, "server_error", "Configuration error: check logs for details.")
  end

  local oidc_issuer_endpoint = service.oidc and service.oidc.issuer_endpoint
  local sso_url = resty_url.parse(oidc_issuer_endpoint)

  -- Extract the realm from the oidc_issuer_endpoint
  local path_components = {}
  for component in string.gmatch(sso_url.path, "[^/]+") do
     table.insert(path_components, component)
  end
  local realm = path_components[3]
  ngx.log(ngx.INFO, "Working on SSO realm ", realm)

  local base_url = string.format("%s://%s:%d", sso_url.scheme, sso_url.host, sso_url.port or resty_url.default_port(sso_url.scheme))
  if self.config.sso_override_hostname then
    base_url = string.format("https://%s", self.config.sso_override_hostname)
    ngx.log(ngx.INFO, "Overriding RH-SSO URL with ", base_url)
  end
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

  if not existing_certificate then
    error(ngx.HTTP_FORBIDDEN, "access_denied", "This client is not registered.")
  end

  local certificate = ngx.var.ssl_client_raw_cert
  local start, len = string.find(certificate, "[-]+BEGIN CERTIFICATE[-]+")
  start = start + len
  local finish = string.find(certificate, "[-]+END CERTIFICATE[-]+")
  certificate = string.sub(certificate, start, finish-1)

  local provided_certificate = ""
  for i in string.gmatch(certificate, "[a-zA-Z0-9+/=]+") do
    provided_certificate = provided_certificate .. i
  end

  if existing_certificate ~= provided_certificate then
    error(ngx.HTTP_FORBIDDEN, "access_denied", "The OpenID Connect client credentials do not match with the SSL/TLS client certificate.")
  end
end

return _M
