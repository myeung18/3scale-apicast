local policy = require('apicast.policy')
local _M = policy.new('Validate that JWT signature is signed by the TLS client certificate')

local jwt = require("resty.jwt")
local http_ng = require("resty.http_ng")
local resty_env = require("resty.env")
local error = require('custom.error')

local function init_config(config)
  local res = {}

  -- Get other values either from provided config or environment variables
  local envs = { "SSO_BACK_HOSTNAME" }
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

  -- Make sure nginx read the POST body
  ngx.req.read_body()

  local form, err = ngx.req.get_post_args()
  if not form then
    error(ngx.HTTP_BAD_REQUEST, "invalid_request", "You need to pass the token request arguments in the post body.")
  end

  local client_assertion = form['client_assertion']
  local client_assertion_type = form['client_assertion_type']
  if not client_assertion_type or client_assertion_type ~= "urn:ietf:params:oauth:client-assertion-type:jwt-bearer" then
    error(ngx.HTTP_BAD_REQUEST, "invalid_request", "Only JWT is allowed for client authentication. See RFC 7523.")
  end

  if not client_assertion then
    error(ngx.HTTP_BAD_REQUEST, "invalid_request", "No client_assertion found.")
  end

  local certificate = ngx.var.ssl_client_raw_cert
  local jwt_obj = jwt:load_jwt(client_assertion)
  if not jwt_obj.valid then
    error(ngx.HTTP_BAD_REQUEST, "invalid_request", "client_assertion is not a valid JWT.")
  end

  if jwt_obj.header.alg ~= "RS256" then
    error(ngx.HTTP_BAD_REQUEST, "invalid_request", "client_assertion must be signed using the RS256 algorithm.")
  end

  jwt_obj = jwt:verify_jwt_obj(certificate, jwt_obj, {})
  if not jwt_obj.verified then
    ngx.log(ngx.WARN, "JWT validation error: ", jwt_obj.reason)
    error(ngx.HTTP_FORBIDDEN, "invalid_request", "client_assertion signature cannot be verified. Check logs for more details.")
  end

  -- Create an HTTP client to speak with RH-SSO
  local httpc = http_ng.new({
    options = {
      ssl = { verify = resty_env.enabled('OPENSSL_VERIFY') }
    }
  })

  -- Forward the request to RH-SSO
  local body = ngx.req.get_body_data()
  local headers = ngx.req.get_headers()
  -- headers.host = self.config.sso_back_hostname
  local url = string.format("https://%s%s", self.config.sso_back_hostname, ngx.var.uri)
  ngx.log(ngx.INFO, "Will forward the request to RH-SSO at ", url)
  local res, err = httpc.post(url, body, {
    headers = headers,
  })
  if not res then
    error(ngx.HTTP_INTERNAL_SERVER_ERROR, "server_error", "Could not get a response from RH-SSO.")
  end

  ngx.status = res.status;
  ngx.header['Content-Type'] = res.headers['Content-Type']
  ngx.say(res.body);
end

return _M
