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
