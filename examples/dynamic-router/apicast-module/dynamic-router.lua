local resty_resolver = require 'resty.resolver'
local resty_url = require 'resty.url'

local _M = { }

local service_catalog_url
local environment_header_name

function _M.setup(proxy)
  -- In case of error during initialization, we will fallback to the default behavior
  local error = false

  -- Get configuration from Environment Variables
  service_catalog_url = os.getenv('DYNAMIC_ROUTER_CATALOG_URL')
  if (service_catalog_url == nil) then
    ngx.log(ngx.ERR, "No environment variable DYNAMIC_ROUTER_CATALOG_URL.")
    error = true
  else
    ngx.log(ngx.INFO, "Using the catalog at " .. (service_catalog_url or "nil"))
  end

  environment_header_name = os.getenv('DYNAMIC_ROUTER_ENVIRONMENT_HEADER_NAME')
  if (environment_header_name == nil) then
    ngx.log(ngx.ERR, "No environment variable DYNAMIC_ROUTER_ENVIRONMENT_HEADER_NAME.")
    error = true
  else
    ngx.log(ngx.INFO, "Using the header " .. (environment_header_name or "nil") .. " as environment")
  end

  if not error then
    -- Update the Proxy Metatable with our custom function
    proxy.get_upstream = get_upstream
  else
    ngx.log(ngx.ERR, "Errors during initialization. Dynamic Routing disabled.")
  end
end

function get_upstream(service)
  service = service or ngx.ctx.service
  ngx.log(ngx.DEBUG, "Dynamically routing service " .. (service.id or "none"))

  local environment = ngx.req.get_headers()[string.lower(environment_header_name)]
  if (environment == nil) then
    ngx.log(ngx.WARN, "No header " .. environment_header_name .. " found, defaulting to '_default'.")
    environment = "_default"
  end

  -- Split the Catalog URL into components
  local url = resty_url.split(service_catalog_url)
  local scheme, _, _, server, port, path =
    url[1], url[2], url[3], url[4], url[5] or resty_url.default_port(url[1]), url[6] or ''

  -- Resolve the DNS name of the Catalog Server
  ngx.ctx.catalog_upstream = resty_resolver:instance():get_servers(server, { port = port })

  -- Share those variables with the Nginx sub-request
  local subrequest_vars = {
    catalog_url = service_catalog_url,
    catalog_host = server,
    service_name = service.id,
    environment = environment
  }
  ngx.log(ngx.INFO, 'Querying the Service Catalog at ', service_catalog_url, " for service id ", service.id, " and environment ", environment)
  local res = ngx.location.capture("/dynamic-router", { vars = subrequest_vars, ctx = { catalog_upstream = ngx.ctx.catalog_upstream } })

  local new_backend
  if (res.status == 200) then
    new_backend = res.body
    ngx.log(ngx.INFO, "Found a backend for service " .. (service.id or "none") .. ": " .. new_backend)
  else
    -- In case we cannot get a positive answer from the Service Catalog, use the default API Backend.
    new_backend = service.api_backend
    ngx.log(ngx.ERR, "Could not get a positive response from the service catalog for service " .. (service.id or "none") .. ": HTTP " .. res.status)
  end

  -- Split the new Backend URL into components
  local url = resty_url.split(new_backend)
  local scheme, _, _, server, port, path =
    url[1], url[2], url[3], url[4], url[5] or resty_url.default_port(url[1]), url[6] or ''

  return {
    server = server,
    host = service.hostname_rewrite or server,
    uri  = scheme .. '://upstream' .. path,
    port = tonumber(port)
  }
end

return _M
