local policy = require('apicast.policy')
local err = require('custom.error')
local _M = policy.new('Require TLS client certificate')

function _M:access()
  ngx.log(ngx.INFO, "VERIFY: ", ngx.var.ssl_client_verify)
  if ngx.var.ssl_client_verify ~= "SUCCESS" then
      err(ngx.HTTP_FORBIDDEN, "invalid_request", "You need to authenticate using an SSL/TLS Client Certificate.")
  end
  ngx.log(ngx.INFO, "Authenticated Client : ", ngx.var.ssl_client_s_dn)
end

return _M
