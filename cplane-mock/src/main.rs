use axum::{
    extract::{Query, State},
    routing::get,
    Json, Router,
};
use serde::{Deserialize, Serialize};

#[derive(Clone)]
struct Context {
    compute_address: String,
}

#[tokio::main]
async fn main() {
    let app = Router::new()
        .route(
            "/authenticate_proxy_request/proxy_get_role_secret",
            get(get_role_secret),
        )
        .route(
            "/authenticate_proxy_request/proxy_wake_compute",
            get(wake_compute),
        )
        .with_state(Context {
            compute_address: std::env::var("PROXY_COMPUTE_ADDR").unwrap(),
        });

    let listener = tokio::net::TcpListener::bind("0.0.0.0:3000").await.unwrap();
    axum::serve(listener, app).await.unwrap();
}

#[derive(Deserialize)]
struct RoleSecretQuery {
    project: String,
}

/// scram_sha_256("password")
const SCRAM_PASSWORD: &str = "SCRAM-SHA-256$4096:M2ZX/kfDSd3vv5iFO/QNUA==$mookt3EiEpd/vMqGbd7df3qVwfyUfM91Ps72sNewNg4=:3nMi8eBSHggIBNSgAik6lQnE3hQcsS+myylZlYgNA1U=";

#[derive(Serialize)]
struct RoleSecretResponse {
    role_secret: &'static str,
    allowed_ips: [&'static str; 1],
    project_id: String,
}

async fn get_role_secret(query: Query<RoleSecretQuery>) -> Json<RoleSecretResponse> {
    let project_id = endpoint_id_to_project_id(&query.project);
    Json(RoleSecretResponse {
        role_secret: SCRAM_PASSWORD,
        allowed_ips: ["127.0.0.1"],
        project_id,
    })
}

#[derive(Deserialize)]
struct WakeComputeQuery {
    project: String,
}

#[derive(Serialize)]
struct WakeComputeResponse {
    pub address: String,
    pub aux: MetricsAuxInfo,
}

#[derive(Serialize)]
pub struct MetricsAuxInfo {
    pub endpoint_id: String,
    pub project_id: String,
    pub branch_id: &'static str,
}

async fn wake_compute(
    query: Query<WakeComputeQuery>,
    state: State<Context>,
) -> Json<WakeComputeResponse> {
    let project_id = endpoint_id_to_project_id(&query.project);
    Json(WakeComputeResponse {
        address: state.compute_address.clone(),
        aux: MetricsAuxInfo {
            endpoint_id: query.0.project,
            project_id,
            branch_id: "main",
        },
    })
}

fn endpoint_id_to_project_id(s: &str) -> String {
    s.strip_prefix("ep-")
        .map(|s| format!("pr-{s}"))
        .unwrap_or_else(|| s.to_owned())
}
