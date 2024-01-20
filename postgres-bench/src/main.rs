use rand::{thread_rng, Rng};
use rand_distr::Zipf;
use std::{sync::Arc, time::Duration};
use tokio::{
    net::TcpStream,
    signal::unix::{signal, SignalKind},
    sync::Semaphore,
    time::Instant,
};
use tokio_postgres::{tls::MakeTlsConnect, Config};
use tokio_postgres_rustls::MakeRustlsConnect;
use tokio_util::task::TaskTracker;

#[tokio::main]
async fn main() {
    let host = std::env::var("PG_HOST").expect("missing var PG_HOST");
    let addr = std::env::var("PG_ADDR").expect("missing var PG_ADDR");
    let connection_rate: f64 = std::env::var("PG_CONNECTION_RATE")
        .expect("missing var PG_CONNECTION_RATE")
        .parse()
        .unwrap();
    let in_flight: u32 = std::env::var("PG_CONNECTING_MAX")
        .expect("missing var PG_CONNECTING_MAX")
        .parse()
        .unwrap();
    let conn_max: u32 = std::env::var("PG_CONNECTION_MAX")
        .expect("missing var PG_CONNECTION_MAX")
        .parse()
        .unwrap();
    // let chunk_rate: f64 = std::env::var("PG_CHUNK_RATE")
    //     .expect("missing var PG_CHUNK_RATE")
    //     .parse()
    //     .unwrap();
    // let chunk_size: u32 = std::env::var("PG_CHUNK_SIZE")
    //     .expect("missing var PG_CHUNK_SIZE")
    //     .parse()
    //     .unwrap();

    let report_interval = Duration::from_secs_f64(5.0);
    let interval = Duration::from_secs_f64(connection_rate.recip());
    let duration_until_full = interval * conn_max;

    let mut tls = tls();
    let tracker = TaskTracker::new();
    let limiter = Arc::new(Semaphore::new(in_flight as usize));
    let conn_limiter = Arc::new(Semaphore::new(conn_max as usize));
    let mut timer = tokio::time::interval(interval);
    timer.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);

    let mut last = Instant::now();
    let mut counter = 0;

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
                "current connecting: {}",
                in_flight - limiter.available_permits() as u32
            );
            println!(
                "current connections: {}",
                conn_max - conn_limiter.available_permits() as u32
            );
            println!();
            last = now;
            counter = 0;
        }
        let exit_time = now + duration_until_full;

        let in_flight = limiter.clone().acquire_owned().await.unwrap();
        let connection_guard = conn_limiter.clone().acquire_owned().await.unwrap();

        let endpoint = thread_rng().sample(endpoint_dist);
        let domain = format!("ep-hello-world-{endpoint}.{host}");
        let dsn = format!("postgresql://demo:password@{domain}/db");
        let config: Config = dsn.parse().unwrap();
        let tls =
            <MakeRustlsConnect as MakeTlsConnect<TcpStream>>::make_tls_connect(&mut tls, &domain)
                .unwrap();

        let connect = TcpStream::connect(addr.clone());

        counter += 1;
        tracker.spawn(async move {
            let socket = connect.await.unwrap();
            let (client, connection) = config.connect_raw(socket, tls).await.unwrap();
            drop(in_flight);

            let handle = tokio::spawn(connection);

            // trigger some constant bandwidth
            // client.query("select data_stream($1, $2)", &[&chunk_rate, &chunk_size]).await.unwrap();
            client.simple_query("select 1;").await.unwrap();

            tokio::time::sleep_until(exit_time).await;
            drop(client);
            handle.await.unwrap().unwrap();

            // release
            drop(connection_guard);
        });
    }

    tracker.close();
    tracker.wait().await;
}

fn tls() -> MakeRustlsConnect {
    let tls_config = rustls::ClientConfig::builder()
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(danger::NoCertificateVerification::new(
            rustls::crypto::ring::default_provider(),
        )))
        .with_no_client_auth();
    MakeRustlsConnect::new(tls_config)
}

mod danger {
    use rustls::client::danger::HandshakeSignatureValid;
    use rustls::crypto::{verify_tls12_signature, verify_tls13_signature, CryptoProvider};
    use rustls::DigitallySignedStruct;
    use rustls_pki_types::{CertificateDer, ServerName, UnixTime};

    #[derive(Debug)]
    pub struct NoCertificateVerification(CryptoProvider);

    impl NoCertificateVerification {
        pub fn new(provider: CryptoProvider) -> Self {
            Self(provider)
        }
    }

    impl rustls::client::danger::ServerCertVerifier for NoCertificateVerification {
        fn verify_server_cert(
            &self,
            _end_entity: &CertificateDer<'_>,
            _intermediates: &[CertificateDer<'_>],
            _server_name: &ServerName<'_>,
            _ocsp: &[u8],
            _now: UnixTime,
        ) -> Result<rustls::client::danger::ServerCertVerified, rustls::Error> {
            Ok(rustls::client::danger::ServerCertVerified::assertion())
        }

        fn verify_tls12_signature(
            &self,
            message: &[u8],
            cert: &CertificateDer<'_>,
            dss: &DigitallySignedStruct,
        ) -> Result<HandshakeSignatureValid, rustls::Error> {
            verify_tls12_signature(
                message,
                cert,
                dss,
                &self.0.signature_verification_algorithms,
            )
        }

        fn verify_tls13_signature(
            &self,
            message: &[u8],
            cert: &CertificateDer<'_>,
            dss: &DigitallySignedStruct,
        ) -> Result<HandshakeSignatureValid, rustls::Error> {
            verify_tls13_signature(
                message,
                cert,
                dss,
                &self.0.signature_verification_algorithms,
            )
        }

        fn supported_verify_schemes(&self) -> Vec<rustls::SignatureScheme> {
            self.0.signature_verification_algorithms.supported_schemes()
        }
    }
}
