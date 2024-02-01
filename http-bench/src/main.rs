use rand::{thread_rng, Rng};
use rand_distr::Zipf;
use std::{net::ToSocketAddrs, sync::Arc, time::Duration};
use tokio::{
    signal::unix::{signal, SignalKind},
    sync::Semaphore,
    time::Instant,
};
use tokio_util::task::TaskTracker;
use typed_json::json;

#[tokio::main]
async fn main() {
    let host = std::env::var("PG_HOST").expect("missing var PG_HOST");
    let addr = std::env::var("PG_ADDR").expect("missing var PG_ADDR");
    let connection_rate: f64 = std::env::var("PG_CONNECTION_RATE")
        .expect("missing var PG_CONNECTION_RATE")
        .parse()
        .unwrap();
    let conn_max: u32 = std::env::var("PG_CONNECTION_MAX")
        .expect("missing var PG_CONNECTION_MAX")
        .parse()
        .unwrap();

    let report_interval = Duration::from_secs_f64(5.0);
    let interval = Duration::from_secs_f64(connection_rate.recip());

    let tracker = TaskTracker::new();
    let conn_limiter = Arc::new(Semaphore::new(conn_max as usize));
    let mut timer = tokio::time::interval(interval);
    timer.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);

    let mut last = Instant::now();
    let mut counter = 0;

    let url = format!("https://api.{host}/sql");
    let addrs: Vec<_> = addr.to_socket_addrs().unwrap().collect();
    let http = reqwest::Client::builder()
        .danger_accept_invalid_certs(true)
        .use_rustls_tls()
        .resolve_to_addrs(&format!("api.{host}"), &addrs)
        .build()
        .unwrap();

    let mut signal = signal(SignalKind::terminate()).unwrap();

    let endpoint_dist = Zipf::new(100000, 1.01).unwrap();
    loop {
        let now = tokio::select! {
            _ = signal.recv() => break,
            now = timer.tick() => now,
        };
        if now - last > report_interval {
            println!(
                "avg connection rate: {}",
                counter as f64 / report_interval.as_secs_f64()
            );
            println!(
                "current connections: {}",
                conn_max - conn_limiter.available_permits() as u32
            );
            println!();
            last = now;
            counter = 0;
        }

        let connection_guard = conn_limiter.clone().acquire_owned().await.unwrap();

        let endpoint = thread_rng().sample(endpoint_dist);
        let domain = format!("ep-hello-world-{endpoint}.{host}");
        let dsn = format!("postgresql://demo:password@{domain}/db");

        counter += 1;
        let req = http.post(&url);
        tracker.spawn(async move {
            req.header("Neon-Connection-String", dsn)
                // .header("Neon-Pool-Opt-In", "true")
                .json(&json!({
                    "query": "select 1",
                    "params": [],
                }))
                .send()
                .await
                .unwrap()
                .error_for_status()
                .unwrap()
                .text()
                .await
                .unwrap();

            // release
            drop(connection_guard);
        });
    }

    tracker.close();
    tracker.wait().await;
}
