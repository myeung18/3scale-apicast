local cjson = require "cjson"

local function err(status, code, msg)
  ngx.status = status
  ngx.header['Content-Type'] = 'application/json'
  local payload = {
    error = code,
    error_description = msg
  }
  ngx.say(cjson.encode(payload))
  ngx.exit(ngx.HTTP_OK)
end

return err
