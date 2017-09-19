# A dynamic routing module for Apicast

## Introduction

This project provides a dynamic routing module for Apicast. It routes the
API request to the appropriate backend, based on an HTTP Header of the request.

A sample use case could be:
 - A Load Balancer identifies the source of the request (internal / external for instance)
 - The LB add the corresponding header (`x-env: dev` or `x-env: prod`)
 - Based on this header, the Apicast routes the API request to the corresponding backend

The API Backends are discovered by querying a Service Catalog. A sample service
catalog is given with this project.

## Development

First of all, setup your development environment as explained [here](../../../README.md#development--testing).

Then, issue the following commands:
```
git clone https://github.com/3scale/apicast.git
cd apicast
luarocks make apicast/*.rockspec --local
ln -s $PWD/examples/dynamic-router/apicast-module/dynamic-router.conf apicast/apicast.d/dynamic-router.conf
ln -s $PWD/examples/dynamic-router/apicast-module/dynamic-router-upstream.conf apicast/sites.d/dynamic-router-upstream.conf
mkdir -p custom
ln -s $PWD/examples/dynamic-router/apicast-module/dynamic-router.lua custom/dynamic-router.lua
```

Configure your apicast as explained [here](../../../doc/parameters.md)
and [here](../../../doc/configuration.md).
```
export APICAST_CUSTOM_CONFIG=custom/dynamic-router
export DYNAMIC_ROUTER_CATALOG_URL=http://127.0.0.1:8082
export DYNAMIC_ROUTER_ENVIRONMENT_HEADER_NAME=x-env
```

Finally, launch apicast:
```
bin/apicast -i 0 -m off
```

## Testing

The default catalog (`catalog.lua`) and the default configuration (`config.json`)
provide a few examples that you can test:
```
curl -D - "http://localhost:8080/echo?user_key=test"
curl -D - "http://localhost:8080/echo?user_key=test" -H "x-env: prod"
curl -D - "http://localhost:8080/echo?user_key=test" -H "x-env: dev"
curl -D - "http://localhost:8080/echo?user_key=test" -H "x-env: bogus"
```
