# Multi-Host Configuration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the proxy configuration to support per-host IP mappings, headers, and secrets so that different backend services receive isolated role sets.

**Architecture:** `SystemConfig` is restructured into a top-level `host_header` field plus a `hosts: HashMap<String, HostConfig>` map. A Rocket request guard `HostName` reads the configured header from each incoming request and resolves which `HostConfig` and secret to use. All secrets are loaded eagerly at startup into a `HostSecrets` map keyed by hostname.

**Tech Stack:** Rust, Rocket (web framework), serde_json (config deserialization), hmac + sha2 + hex (token creation — unchanged).

## Global Constraints

- All changes are in `src/main.rs`, `test_data/config.json`, and `README.md` — no new files
- The `create_token` function and its two unit tests must remain byte-for-byte identical in behavior
- A missing or unreadable secret file must panic at startup with a message that includes the hostname
- An absent or unrecognized host header must produce a `401 Unauthorized` response — never a 500 or fallback

---

### Task 1: Update test_data/config.json to the new multi-host format

**Files:**
- Modify: `test_data/config.json`

**Interfaces:**
- Produces: a valid config file in the shape `{ host_header, hosts: { <hostname>: { ip_mapping, user_header, roles_header, token_header, secret_file } } }` that the updated binary will accept

- [ ] **Step 1: Replace the contents of test_data/config.json**

  Write the following — a single host named `localhost` that preserves all four existing IP entries and reuses the existing `test_data/key` secret file:

  ```json
  {
    "host_header": "X-Original-Host",
    "hosts": {
      "localhost": {
        "ip_mapping": {
          "127.0.0.1": {
            "user": "admin",
            "roles": [
              "administrator",
              "editor"
            ]
          },
          "::1": {
            "user": "admin",
            "roles": [
              "administrator",
              "editor"
            ]
          },
          "192.168.0.12": {
            "user": "editor_user",
            "roles": [
              "editor"
            ]
          },
          "192.168.0.13": {
            "user": "guest",
            "roles": [
              "viewer"
            ]
          }
        },
        "user_header": "X-Auth-UserName",
        "roles_header": "X-Roles",
        "token_header": "X-Auth-Token",
        "secret_file": "test_data/key"
      }
    }
  }
  ```

- [ ] **Step 2: Commit**

  ```bash
  git add test_data/config.json
  git commit -m "update test config to multi-host format"
  ```

---

### Task 2: Rewrite src/main.rs with new types, request guard, handler, and startup

**Files:**
- Modify: `src/main.rs`

**Interfaces:**
- Consumes: `test_data/config.json` in the new multi-host format (Task 1)
- Produces:
  - `SystemConfig { host_header: String, hosts: HashMap<String, HostConfig> }`
  - `HostConfig { ip_mapping: HashMap<IpAddr, UserInfo>, user_header: String, roles_header: String, token_header: String, secret_file: String }`
  - `HostSecrets(HashMap<String, Vec<u8>>)`
  - `HostName(String)` implementing `FromRequest`
  - `authorize` handler using `HostName`, `SystemConfig`, `HostSecrets`

- [ ] **Step 1: Run the existing tests to establish a baseline**

  ```bash
  cargo test
  ```

  Expected output: two tests pass — `create_token_ok` and `create_token_fail`.

- [ ] **Step 2: Replace the full contents of src/main.rs**

  ```rust
  #[macro_use]
  extern crate rocket;
  use hmac::digest::InvalidLength;
  use rocket::{
      Request,
      State,
      http::{Header, Status},
      request::{FromRequest, Outcome},
      response::Responder,
      serde::json::{Json, serde_json},
  };
  use serde::{Deserialize, Serialize};
  use std::{collections::HashMap, env, fs, net::IpAddr};
  use thiserror::Error;

  #[derive(Debug, Error)]
  enum SiapError {
      #[error("HMAC error: invalid length")]
      HmacError(#[from] InvalidLength),
  }

  #[derive(Serialize)]
  struct SystemInfo {
      name: &'static str,
      version: &'static str,
  }

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

  #[derive(Deserialize)]
  struct UserInfo {
      user: String,
      roles: Vec<String>,
  }

  struct HostSecrets(HashMap<String, Vec<u8>>);

  impl SystemConfig {
      pub fn from_file(path: &str) -> Result<Self, Box<dyn std::error::Error>> {
          let content = fs::read_to_string(path)?;
          let config: SystemConfig = serde_json::from_str(&content)?;
          Ok(config)
      }
  }

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

  #[derive(Responder)]
  enum SiapResponse {
      Authorized {
          inner: Status,
          user: Header<'static>,
          roles: Header<'static>,
          token: Header<'static>,
      },
      Unauthorized {
          inner: Status,
      },
  }

  #[get("/auth")]
  fn authorize(
      client_real_ip: IpAddr,
      host_name: HostName,
      config: &State<SystemConfig>,
      secrets: &State<HostSecrets>,
  ) -> SiapResponse {
      log::info!("Authorization request from IP: {}", client_real_ip);
      let host_config = match config.hosts.get(&host_name.0) {
          Some(hc) => hc,
          None => {
              log::warn!("No configuration for host: {}", host_name.0);
              return SiapResponse::Unauthorized {
                  inner: Status::Unauthorized,
              };
          }
      };
      let secret = secrets.0.get(&host_name.0).unwrap();
      match host_config.ip_mapping.get(&client_real_ip) {
          Some(user_info) => {
              log::info!(
                  "Authorized user: {}, roles: {:?}",
                  user_info.user,
                  user_info.roles
              );
              let roles_str = user_info.roles.join(",");
              match create_token(&user_info.user, secret) {
                  Ok(token) => SiapResponse::Authorized {
                      inner: Status::Ok,
                      user: Header::new(host_config.user_header.clone(), user_info.user.clone()),
                      roles: Header::new(host_config.roles_header.clone(), roles_str),
                      token: Header::new(host_config.token_header.clone(), token),
                  },
                  Err(e) => {
                      log::error!("Failed to create token: {}", e);
                      SiapResponse::Unauthorized {
                          inner: Status::InternalServerError,
                      }
                  }
              }
          }
          None => {
              log::warn!("Unauthorized access attempt from IP: {}", client_real_ip);
              SiapResponse::Unauthorized {
                  inner: Status::Unauthorized,
              }
          }
      }
  }

  // These environment variables are set by Cargo at build time.
  const SYSTEM_NAME: &str = env!("CARGO_PKG_NAME");
  const SYSTEM_VERSION: &str = env!("CARGO_PKG_VERSION");

  #[get("/info")]
  fn info() -> Json<SystemInfo> {
      Json(SystemInfo {
          name: SYSTEM_NAME,
          version: SYSTEM_VERSION,
      })
  }

  #[rocket::main]
  async fn main() {
      env_logger::init();

      let config = SystemConfig::from_file(
          &env::var("CONFIG_PATH").expect("Failed to get CONFIG_PATH environment variable"),
      )
      .expect("Failed to load config");

      let mut secrets = HashMap::new();
      for (host, host_config) in &config.hosts {
          let key = rocket::tokio::fs::read(&host_config.secret_file)
              .await
              .unwrap_or_else(|_| panic!("Failed to load secret key for host: {}", host));
          secrets.insert(host.clone(), key);
      }

      let rocket = rocket::build()
          .mount("/", routes![info, authorize])
          .manage(config)
          .manage(HostSecrets(secrets));
      if let Err(e) = rocket.launch().await {
          println!("Whoops! Rocket didn't launch!");
          drop(e);
      };
  }

  fn create_token(user: &str, secret: &[u8]) -> Result<String, SiapError> {
      use hex;
      use hmac::{Hmac, Mac};
      use sha2::Sha256;

      type HmacSha256 = Hmac<Sha256>;
      let mut mac = HmacSha256::new_from_slice(secret).map_err(SiapError::HmacError)?;
      mac.update(user.as_bytes());
      let result = mac.finalize();
      let code_bytes = result.into_bytes();
      Ok(hex::encode(code_bytes))
  }

  #[cfg(test)]
  mod tests {
      use super::*;

      #[test]
      fn create_token_ok() {
          let result = create_token("foo", "the_secret".as_bytes()).unwrap();
          assert_eq!(
              result,
              "3f0786e96b20b0102b77f1a49c041be6977cfb3bf78c41a12adc121cd9b4e68a"
          );
      }

      #[test]
      fn create_token_fail() {
          let result = create_token("foo2", "the_secret".as_bytes()).unwrap();
          assert_ne!(
              result,
              "3f0786e96b20b0102b77f1a49c041be6977cfb3bf78c41a12adc121cd9b4e68a"
          );
      }
  }
  ```

- [ ] **Step 3: Run the tests**

  ```bash
  cargo test
  ```

  Expected output: two tests pass — `create_token_ok` and `create_token_fail`. Compilation of the full crate (including `main` and `authorize`) must succeed for the tests to run.

- [ ] **Step 4: Commit**

  ```bash
  git add src/main.rs
  git commit -m "implement multi-host configuration support"
  ```

---

### Task 3: Update README.md to reflect new config structs

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: final types from Task 2

- [ ] **Step 1: Replace the Configuration section of README.md**

  Find the block that shows the `SystemConfig` and `UserInfo` Rust structs and replace it with the following (keep all surrounding text unchanged):

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

  #[derive(Deserialize)]
  struct UserInfo {
      user: String,
      roles: Vec<String>,
  }
  ```

  The surrounding prose should also be updated to clarify that `host_header` names the request header nginx passes to identify the target service, and that each key in `hosts` is the hostname string matched against that header value.

- [ ] **Step 2: Commit**

  ```bash
  git add README.md
  git commit -m "update README to document multi-host config structs"
  ```
