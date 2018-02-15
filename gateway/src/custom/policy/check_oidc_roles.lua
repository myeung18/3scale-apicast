local policy = require('apicast.policy')
local _M = policy.new('Check the OpenID Connect realm and resource roles')

local jwt = require("resty.jwt")
local cjson = require("cjson")

local function init_config(config)
  local res = {}

  local realm_roles = {}
  for role, policy in pairs(config.realm_roles or {}) do
    policy = string.lower(policy)
    if policy == 'forbidden' or policy == 'required' then
      realm_roles[role] = policy
    else
      ngx.log(ngx.WARN, string.format("Unknown policy '%s' for role '%s'. Ignoring...", policy, role))
    end
  end

  local client_roles = {}
  for client, roles in pairs(config.client_roles or {}) do
    local new_roles = {}
    for role, policy in pairs(roles or {}) do
      policy = string.lower(policy)
      if policy == 'forbidden' or policy == 'required' then
        new_roles[role] = policy
      else
        ngx.log(ngx.WARN, string.format("Unknown policy '%s' for role '%s/%s'. Ignoring...", policy, client, role))
      end
    end
    client_roles[client] = new_roles
  end

  res.realm_roles = realm_roles
  res.client_roles = client_roles

  return res
end

local new = _M.new
function _M.new(config)
  local self = new()
  self.config = init_config(config or {})
  return self
end

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
  local jwt = context.jwt
  if not jwt then
    ngx.log(ngx.WARN, "Could not find any JWT token in the context !")
    error(ngx.HTTP_FORBIDDEN, "access_denied", "Could not find any JWT token in the context !")
    return
  end

  -- The resource_access is always present in the token
  -- But the realm_access is only present when there is at least one realm role
  if not jwt.resource_access then
    ngx.log(ngx.WARN, "No resource_access claim in the OpenID Connect token !")
    error(ngx.HTTP_FORBIDDEN, "access_denied", "No resource_access claim in the OpenID Connect token !")
    return
  end

  -- Compute the lookup tables
  local realm_access = {}
  for i, role in ipairs(jwt.realm_access and jwt.realm_access.roles or {}) do
    realm_access[role] = true
  end

  local resource_access = {}
  for client, roles in pairs(jwt.resource_access) do
    local new_roles = {}
    for i, role in ipairs(roles.roles or {}) do
      new_roles[role] = true
    end
    resource_access[client] = new_roles
  end

  -- Enforce realm roles policies
  for role, decision in pairs(self.config.realm_roles) do
    if decision == 'required' and not realm_access[role] then
      error(ngx.HTTP_FORBIDDEN, "access_denied", string.format("Required realm role '%s' is missing from your access_token.", role))
      return
    end
    if decision == 'forbidden' and realm_access[role] then
      error(ngx.HTTP_FORBIDDEN, "access_denied", string.format("Forbidden realm role '%s' is present in your access_token.", role))
      return
    end
  end

  -- Enforce client roles policies
  for client, roles in pairs(self.config.client_roles) do
    for role, decision in pairs(roles) do
      if decision == 'required' and not (resource_access[client] and resource_access[client][role]) then
        error(ngx.HTTP_FORBIDDEN, "access_denied", string.format("Required client role '%s/%s' is missing from your access_token.", client, role))
        return
      end
      if decision == 'forbidden' and resource_access[client] and resource_access[client][role] then
        error(ngx.HTTP_FORBIDDEN, "access_denied", string.format("Forbidden client role '%s/%s' is present in your access_token.", client, role))
        return
      end
    end
  end

end

return _M
