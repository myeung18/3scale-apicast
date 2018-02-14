# An APIcast customization that enables TLS client certificate authentication

## The problem to solve

The idea behind this APIcast customization is to enforce SSL/TLS client certificate
authentication in order to gain access to an API in a manageable way.

Namely, SSL/TLS client certificate authentication is easy. Just use the `ssl_verify_client`,
`ssl_client_certificate` and `ssl_crl` directives of your Nginx configuration.

But then comes the Access Control: how do I make sure that this client (rightfully
authenticated using his client certificate) is authorized to call this API (or
subset of this API) ?

One way to circumvent the problem is to ask the client to authenticate again with
another authentication method (OpenID Connect or API Key) and use this secondary
method for Access Control, which is hopefully already handled by 3scale.

But if there is no link between the client certificate and the secondary authentication
method (OpenID Connect or API Key), a tricky client that stole the secondary authentication
means of another client could use it with his own client certificate. Since both
authentication means are valid, the misuse would remain unnoticed.

Using client certificates this way is doable for a dozen of clients with acceptable risks.
But scaling to a larger number would require a more robust method.

## How it solves the problem

The idea behind this APIcast customization is to bind the client certificate used at
the SSL/TLS layer with the HMAC keys used during the token request (which implies that
all clients will use [OpenID Connect with JWT client authentication](https://tools.ietf.org/html/rfc7523)).

This APIcast customization is in fact a reverse proxy for Red Hat SSO.

It exposes two endpoints:
- A registration endpoint where the client can bind its SSL/TLS client certificate
  with his 3scale application/RH-SSO client.
- A token endpoint where the client can ask for an access_token by authenticating
  with his SSL/TLS client certificate and his RFC7523 assertion.

The registration endpoint is protected by an API Key (as any API exposed by 3scale)
and asks for the client_id of the application to bind with the SSL/TLS certificate.
To use the registration endpoint, the client has to authenticate with the SSL/TLS client
certificate he plans to use (and this enables Proof-of-Possession).

The registration endpoint then:
- makes sure the client certificate authentication has been performed
- makes sure that both the API Key and the client_id belongs to two applications
  of the same developer account.
- makes sure that a client certificate is not already registered for this client_id.
- registers the SSL/TLS client certificate on Red Hat SSO as a valid RFC7523 key
  for this client_id.

The token endpoint then:
- makes sure the client certificate authentication has been performed
- makes sure the JWT client assertion has been signed with the same key as used
  during the SSL/TLS client certificate authentication.
- then forwards the request to the RH-SSO token endpoint that takes care of generating
  the token.

## How to deploy

To deploy this APIcast customization you can use the [provided OpenShift template](openshift/sso-proxy-template.yaml).

The relevant parameters of this template are:
- `SERVICE_ID`: the service id of the 3scale service protecting the registration endpoint
- `SERVICE_TOKEN`: the service token used to authenticate on the 3scale backend
- `SSO_BACK_HOSTNAME`: the Red Hat SSO Service to protect (usually `secure-sso.yournamespace.svc.cluster.local:8443`)
- `SSO_REGISTER_HOSTNAME`: the hostname for your registration endpoint
- `SSO_PROXY_HOSTNAME`: the hostname for the token endpoint
- `SSO_REALMS_TO_PROTECT`: the SSO realms to protect using this customization (separated by pipes)
- `IMAGESTREAM_TAG`: the OpenShift ImageStreamTag of your custom APIcast build
- `IMAGESTREAM_NAMESPACE`: the namespace of the OpenShift ImageStreamTag of your custom APIcast build

Your trusted CA bundle and CRL needs to be set in a ConfigMap named by default
`sso-proxy-ca` (keys `ca-bundle.crt` and `crl.pem`).

## How to test

To test this customization, you will need a CA with some client certificates and a CRL.
If you do not have one, you can use [easypki](https://github.com/google/easypki).

And you need a tool to sign your JWT client assertions. If you do not have one, you
can use [go-jwt](https://github.com/dgrijalva/jwt-go).

To call the registration endpoint protected by API Key '123' to register the client_id '456'
with its client certificate being stored in the `client.key` and `client.crt` files, you can use:

```
cd tests
export SSO_REGISTER_HOSTNAME=my.registration.endpoint
export SSO_REALM=3scale
./register.sh 123 456
```

You can then validate that your certificate has been registered using:
```
cd tests
export SSO_FRONT_HOSTNAME=my.token.endpoint
export SSO_REALM=3scale
./validate.sh 456 client.key client.crt
```

## How to build

### On your workstation

See [Development and testing](README.md#development--testing).

### On OpenShift

Use the template provided in [pull request #583](https://github.com/3scale/apicast/pull/583).
