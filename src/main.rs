#[macro_use]
extern crate rocket;
use hmac::digest::InvalidLength;
use rocket::{
    State,
    http::{Header, Status},
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

struct SecretKey(Vec<u8>);

impl SystemConfig {
    pub fn from_file(path: &str) -> Result<Self, Box<dyn std::error::Error>> {
        let content = fs::read_to_string(path)?;
        let config: SystemConfig = serde_json::from_str(&content)?;
        Ok(config)
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
    config: &State<SystemConfig>,
    secret_key: &State<SecretKey>,
) -> SiapResponse {
    log::info!("Authorization request from IP: {}", client_real_ip);
    match config.ip_mapping.get(&client_real_ip) {
        Some(user_info) => {
            log::info!(
                "Authorized user: {}, roles: {:?}",
                user_info.user,
                user_info.roles
            );
            let roles_str = user_info.roles.join(",");
            match create_token(&user_info.user, &secret_key.0) {
                Ok(token) => SiapResponse::Authorized {
                    inner: Status::Ok,
                    user: Header::new(config.user_header.clone(), user_info.user.clone()),
                    roles: Header::new(config.roles_header.clone(), roles_str),
                    token: Header::new(config.token_header.clone(), token),
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

    let secret_key = SecretKey(
        rocket::tokio::fs::read(config.secret_file.clone())
            .await
            .expect("Failed to load secret key file"),
    );

    let rocket = rocket::build()
        .mount("/", routes![info, authorize])
        .manage(config)
        .manage(secret_key);
    if let Err(e) = rocket.launch().await {
        println!("Whoops! Rocket didn't launch!");
        // We drop the error to get a Rocket-formatted panic.
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
