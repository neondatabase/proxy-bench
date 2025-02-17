use axum::{
    extract::{Query, State},
    routing::get,
    Json, Router,
};
use serde::{Deserialize, Serialize};
use tokio::signal::unix::{signal, SignalKind};

#[derive(Clone)]
struct Context {
    compute_address: String,
}

#[tokio::main]
async fn main() {
    println!("Starting cplane-mock");

    let app = Router::new()
        .route(
            "/proxy/api/v1/get_endpoint_access_control",
            get(get_endpoint_access_control),
        )
        .route(
            "/proxy/api/v1/wake_compute",
            get(wake_compute),
        )
        .with_state(Context {
            compute_address: std::env::var("PROXY_COMPUTE_ADDR").unwrap(),
        });

    let mut signal = signal(SignalKind::terminate()).unwrap();
    let listener = tokio::net::TcpListener::bind("0.0.0.0:3010").await.unwrap();
    axum::serve(listener, app)
        .with_graceful_shutdown(async move {
            signal.recv().await;
        })
        .await
        .unwrap();
}

#[derive(Deserialize)]
struct RoleSecretQuery {
    role: String,
    endpointish: String,
}

/// scram_sha_256("password")
const SCRAM_PASSWORD: &str = "SCRAM-SHA-256$4096:M2ZX/kfDSd3vv5iFO/QNUA==$mookt3EiEpd/vMqGbd7df3qVwfyUfM91Ps72sNewNg4=:3nMi8eBSHggIBNSgAik6lQnE3hQcsS+myylZlYgNA1U=";

#[derive(Serialize)]
struct RoleSecretResponse {
    role_secret: &'static str,
    allowed_ips: Option<Vec<String>>,
    allowed_vpc_endpoint_ids: Option<Vec<String>>,
    project_id: Option<String>,
    account_id: Option<String>,
    block_public_connections: Option<bool>,
    block_vpc_connections: Option<bool>,
}

async fn get_endpoint_access_control(query: Query<RoleSecretQuery>) -> Json<RoleSecretResponse> {
    let project_id = endpoint_id_to_project_id(&query.endpointish);
    println!("get_endpoint_access_control: project_id: {}", project_id);
    Json(RoleSecretResponse {
        role_secret: SCRAM_PASSWORD,
        allowed_ips: None,
        allowed_vpc_endpoint_ids: None,
        project_id: Some(project_id),
        account_id: None,
        block_public_connections: None,
        block_vpc_connections: None,
    })
}

#[derive(Deserialize)]
struct WakeComputeQuery {
    endpointish: String,
    application_name: Option<String>,
    session_id: Option<String>,
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
    println!("Received wake_compute request with params: {:?}", query.0.endpointish);
    let project_id = endpoint_id_to_project_id(&query.endpointish);
    Json(WakeComputeResponse {
        address: state.compute_address.clone(),
        aux: MetricsAuxInfo {
            endpoint_id: query.0.endpointish,
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
