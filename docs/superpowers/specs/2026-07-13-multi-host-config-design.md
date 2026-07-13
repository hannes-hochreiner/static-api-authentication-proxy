# Multi-Host Configuration Design

**Date:** 2026-07-13
**Status:** Approved

## Context

The static-ip-authentication-proxy currently uses a single flat configuration that applies globally to all requests. This means all services sharing the proxy see the same IP mapping, header names, and secret. The goal of this change is to support per-host configuration so that role sets are isolated between services and different header names or secrets can be used per service.

The primary use case is two CouchDB-backed services (`travel.cloud.hochreiner.net` and `sumptureg.cloud.hochreiner.net`) that share users but must not disclose each other's roles. The design is open-ended enough to accommodate future non-CouchDB backends.

## Requirements

- Each configured host has its own `ip_mapping`, `user_header`, `roles_header`, `token_header`, and `secret_file`
- nginx identifies the target service by passing a header (e.g. `X-Original-Host`) whose name is itself configurable
- If the host header is absent or names a host not in the configuration, the response is `401 Unauthorized`
- There is no global fallback or wildcard host entry
- Missing or unreadable secret files are fatal startup errors

## Config Format

The flat `SystemConfig` is replaced with a two-level structure:

```json
{
  "host_header": "X-Original-Host",
  "hosts": {
    "travel.cloud.hochreiner.net": {
      "ip_mapping": {
        "192.168.0.12": { "user": "alice", "roles": ["editor"] }
      },
      "user_header": "X-Auth-CouchDB-UserName",
      "roles_header": "X-Auth-CouchDB-Roles",
      "token_header": "X-Auth-CouchDB-Token",
      "secret_file": "/run/secrets/travel_key"
    },
    "sumptureg.cloud.hochreiner.net": {
      "ip_mapping": {
        "192.168.0.12": { "user": "alice", "roles": ["admin"] }
      },
      "user_header": "X-Auth-CouchDB-UserName",
      "roles_header": "X-Auth-CouchDB-Roles",
      "token_header": "X-Auth-CouchDB-Token",
      "secret_file": "/run/secrets/sumptureg_key"
    }
  }
}
```

`test_data/config.json` is updated to this new shape, reusing the existing `test_data/key` file as the secret for the test host(s).

## Rust Types

```rust
#[derive(Deserialize)]
struct SystemConfig {
    host_header: String,
    hosts: HashMap<String, HostConfig>,
}

#[derive(Deserialize)]
struct HostConfig {
    ip_mapping: HashMap<IpAddr, UserInfo>,
    user_header: String,
    roles_header: String,
    token_header: String,
    secret_file: String,
}

// UserInfo is unchanged
#[derive(Deserialize)]
struct UserInfo {
    user: String,
    roles: Vec<String>,
}

// Replaces SecretKey — one secret per host, keyed by hostname
struct HostSecrets(HashMap<String, Vec<u8>>);
```

Both `SystemConfig` and `HostSecrets` are registered as Rocket managed state.

## Host Resolution: Request Guard

A `HostName` request guard reads the header name from managed `SystemConfig` state and extracts its value from the incoming request. A missing header fails the guard with `401` before the handler runs.

```rust
struct HostName(String);

#[rocket::async_trait]
impl<'r> FromRequest<'r> for HostName {
    type Error = ();

    async fn from_request(request: &'r Request<'_>) -> Outcome<Self, Self::Error> {
        let config = request.rocket().state::<SystemConfig>().unwrap();
        match request.headers().get_one(&config.host_header) {
            Some(h) => Outcome::Success(HostName(h.to_string())),
            None => Outcome::Error((Status::Unauthorized, ())),
        }
    }
}
```

## Auth Handler

```rust
#[get("/auth")]
fn authorize(
    client_real_ip: IpAddr,
    host_name: HostName,
    config: &State<SystemConfig>,
    secrets: &State<HostSecrets>,
) -> SiapResponse {
    let host_config = match config.hosts.get(&host_name.0) {
        Some(hc) => hc,
        None => return SiapResponse::Unauthorized { inner: Status::Unauthorized },
    };
    let secret = secrets.0.get(&host_name.0).unwrap(); // safe: built from same keys at startup
    // ip_mapping lookup, token creation, and header response are unchanged
}
```

## Startup

`main` iterates over all hosts in the loaded config to build `HostSecrets`. A missing or unreadable secret file panics at startup.

```rust
let mut secrets = HashMap::new();
for (host, host_config) in &config.hosts {
    let key = rocket::tokio::fs::read(&host_config.secret_file)
        .await
        .unwrap_or_else(|_| panic!("Failed to load secret key for host: {}", host));
    secrets.insert(host.clone(), key);
}

rocket::build()
    .mount("/", routes![info, authorize])
    .manage(config)
    .manage(HostSecrets(secrets));
```

## Testing

The two existing unit tests (`create_token_ok`, `create_token_fail`) are unaffected — `create_token` is unchanged.

`test_data/config.json` is updated to the new format. The existing `test_data/key` file is reused as the secret for the test host entry. No new integration tests are in scope.

## Documentation

`README.md` documents the `SystemConfig` Rust struct inline. It must be updated to reflect the new `SystemConfig` / `HostConfig` split so the documented types stay accurate.

## Out of Scope

- Wildcard or default host entries
- Shared/inherited config fields across hosts
- Hot-reloading config without restart
- Per-directory config files
