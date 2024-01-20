use std::sync::Arc;
use tokio::sync::Semaphore;
use tokio_postgres_rustls::MakeRustlsConnect;
use tokio_util::task::TaskTracker;

#[tokio::main]
async fn main() {
    let tls_config = rustls::ClientConfig::builder()
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(danger::NoCertificateVerification::new(
            rustls::crypto::ring::default_provider(),
        )))
        .with_no_client_auth();
    let tls_config = MakeRustlsConnect::new(tls_config);

    let t = TaskTracker::new();
    let s = Arc::new(Semaphore::new(100));

    for i in 0..10000 {
        let s = s.clone().acquire_owned().await.unwrap();
        let conn_str = format!("postgresql://demo:password@ep-{i}.localtest.me/db");
        let tls_config = tls_config.clone();
        t.spawn(async move {
            let _s = s;
            let (client, connection) = tokio_postgres::connect(&conn_str, tls_config)
                .await
                .unwrap();
            tokio::spawn(connection);
            client.simple_query("select 1;").await.unwrap();
        });
    }

    t.close();
    t.wait().await;
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