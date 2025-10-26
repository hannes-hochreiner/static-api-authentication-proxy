# Static IP Authentication Proxy
A simple web proxy authenticating users based on their IP.

## Configuration
The application reads the configuration file pointed to by the environment variable ``CONFIG_PATH`` at start up.
The configuration file can be any format that can be deserialized into a ``SystemConfig`` Rust object.
```rust
#[derive(Deserialize)]
struct SystemConfig {
    ip_mapping: HashMap<IpAddr, UserInfo>,
    user_header: String,
    roles_header: String,
    token_header: String,
    secret_file: String,
}

#[derive(Deserialize)]
struct UserInfo {
    user: String,
    roles: Vec<String>,
}
```
In addition, all environment variables defined by the ``log`` and ``rocket`` crates can be used.

## References
- [CouchDB - Proxy Authentication](https://docs.couchdb.org/en/stable/api/server/authn.html#proxy-authentication)
- [CouchDB - ctthp-auth secret](https://docs.couchdb.org/en/stable/config/auth.html#chttpd_auth/secret)
- [CouchDB - proxy use secret](https://docs.couchdb.org/en/stable/config/auth.html#chttpd_auth/proxy_use_secret)
- [nginx - Authentication Sub-request](https://docs.nginx.com/nginx/admin-guide/security-controls/configuring-subrequest-authentication/)
- [nginx - auth request module](https://nginx.org/en/docs/http/ngx_http_auth_request_module.html)
- [authentication guide](https://www.bomberbot.com/proxy/securing-your-apis-with-nginx-auth_request-the-definitive-guide/)
- [nginx - upstream variables](https://nginx.org/en/docs/http/ngx_http_upstream_module.html#var_upstream_http_)
- [nginx - http variable mapping rule](https://nginx.org/en/docs/http/ngx_http_core_module.html#var_http_)
- [nginx - proxy set header](https://nginx.org/en/docs/http/ngx_http_proxy_module.html#proxy_set_header)

## License

This work is licensed under the MIT or Apache 2.0 license.

`SPDX-License-Identifier: MIT OR Apache-2.0`
