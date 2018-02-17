local policy = require('apicast.policy')
local _M = policy.new('Authenticate a client using his API Key or his SSL/TLS client certificate')

local openssl = require('openssl')
local sha1 = require('sha1')
local cjson = require('cjson')

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

function _M:access(context, host)
  local service = context.service
  if not service then
    ngx.log(ngx.WARN, "Service configuration could not be found.")
    error(ngx.HTTP_INTERNAL_SERVER_ERROR, "server_error", "Configuration error: check logs for details.")
  end

  if service.backend_version ~= 1 and service.backend_version ~= "1" then
    ngx.log(ngx.WARN, "This policy can only be used with services configured with API Key authentication.")
    error(ngx.HTTP_INTERNAL_SERVER_ERROR, "server_error", "Configuration error: check logs for details.")
  end

  if service.credentials.location ~= "headers" then
    ngx.log(ngx.WARN, "This policy can only be used with services configured to receive credentials as HTTP headers.")
    error(ngx.HTTP_INTERNAL_SERVER_ERROR, "server_error", "Configuration error: check logs for details.")
  end

  local user_key_header = service.credentials.user_key
  local user_key_value = ngx.req.get_headers()[user_key_header]

  if user_key_value and string.sub(user_key_value, 1, string.len("certificate-")) == "certificate-" then
    error(ngx.HTTP_FORBIDDEN, "access_denied", "This API Key cannot be used directly. You need to authenticate using your SSL/TLS Client Certificate only.")
  end

  if not user_key_value then
    if ngx.var.ssl_client_verify ~= "SUCCESS" then
      error(ngx.HTTP_FORBIDDEN, "access_denied", "You need to authenticate using your SSL/TLS Client Certificate.")
    end

    local certificate = ngx.var.ssl_client_raw_cert
    local x509 = openssl.x509.read(certificate)
    x509 = x509 and x509:parse()
    if not x509 then
      error(ngx.HTTP_FORBIDDEN, "access_denied", "Cannot read and parse the SSL/TLS client certificate.")
    end

    local dn = x509.subject
    if dn:entry_count() < 1 then
      error(ngx.HTTP_FORBIDDEN, "access_denied", "The SSL/TLS client certificate must have a Subject DN.")
    end

    local common_name = ""
    for i = 0, dn:entry_count()-1 do
      local rdn = dn:get_entry(i, true)
      for k,v in pairs(rdn) do
        local kind = k:ln()
        local value = v:toutf8()
        if kind == "commonName" then
          common_name = common_name .. value
        end
      end
    end

    if common_name == "" then
      error(ngx.HTTP_FORBIDDEN, "access_denied", "The SSL/TLS client certificate must have a Common Name in its DN.")
    end

    local identification_data = string.format("%s-%s", service.id, common_name)
    local hash = sha1(identification_data)

    ngx.req.set_header(user_key_header, string.format("certificate-%s", hash))
  end
end

return _M
