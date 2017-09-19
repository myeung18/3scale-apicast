# Dynamic Routing for Apicast

## Introduction

This project provides a dynamic routing module for Apicast. It routes the
API request to the appropriate backend, based on an HTTP Header of the request.

A sample use case could be:
 - A Load Balancer in front of Apicast identifies the source of the request (`internal`/`external` or `dev`/`prod`)
 - The LB add the corresponding header (`x-env: dev` or `x-env: prod` for instance)
 - Based on this header, the Apicast routes the API request to the corresponding backend

The API Backends are discovered by querying a Service Catalog. A sample service
catalog is given with this project.

It is designed to be hosted on Apicast itself (or any nginx instance) in order
to simplify the deployment.

## Deployment

Put `dynamic-router.conf` in `/opt/app-root/src/apicast.d/dynamic-router.conf`:
```
oc create configmap apicast.d --from-file=apicast-module/dynamic-router.conf
oc volume dc/apicast-staging --add --name=apicastd --mount-path /opt/app-root/src/apicast.d/ --type=configmap --configmap-name=apicast.d
```

Put `dynamic-router-upstream.conf` and `catalog.conf` in `/opt/app-root/src/sites.d/`:
```
oc create configmap sites.d --from-file=apicast-module/dynamic-router-upstream.conf --from-file=catalog/catalog.conf
oc volume dc/apicast-staging --add --name=sitesd --mount-path /opt/app-root/src/sites.d/ --type=configmap --configmap-name=sites.d
```

Put `catalog.lua` and `dynamic-router.lua` in `/opt/app-root/src/src/custom/`:
```
oc create configmap apicast-custom-module --from-file=apicast-module/dynamic-router.lua --from-file=catalog/catalog.lua
oc volume dc/apicast-staging --add --name=apicast-custom-module --mount-path /opt/app-root/src/src/custom/ --type=configmap --configmap-name=apicast-custom-module
```

Set the configuration required by the catalog and the dynamic routing module as environment variables and re-deploy apicast:
```
oc env dc/apicast-staging APICAST_CUSTOM_CONFIG=custom/dynamic-router
oc env dc/apicast-staging DYNAMIC_ROUTER_CATALOG_URL=http://127.0.0.1:8082
oc env dc/apicast-staging DYNAMIC_ROUTER_ENVIRONMENT_HEADER_NAME=x-env
oc rollout latest apicast-staging
```

Once, you get it to work on `apicast-staging`, you can do the same on `apicast-production`.
