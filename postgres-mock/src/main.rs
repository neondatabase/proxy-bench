use std::time::Duration;

use bytes::BytesMut;
use hmac::{Hmac, Mac};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{TcpListener, TcpStream},
    select,
    signal::unix::{signal, SignalKind},
};

#[tokio::main]
async fn main() {
    let mut signal = signal(SignalKind::terminate()).unwrap();
    let listener = TcpListener::bind("0.0.0.0:5432").await.unwrap();
    loop {
        select! {
            s = listener.accept() => tokio::spawn(handle(s.unwrap().0)),
            _ = signal.recv() => break,
        };
    }
}

async fn handle(mut s: TcpStream) {
    let mut buf = BytesMut::new();
    handshake(&mut s, &mut buf).await;

    loop {
        // Ready for query (idle)
        s.write_all(&b"Z\x00\x00\x00\x05I"[..]).await.unwrap();
        let query = loop {
            if buf.len() > 5 {
                let len = u32::from_be_bytes(buf[1..5].try_into().unwrap()) as usize + 1;
                if buf.len() >= len {
                    break buf.split_to(len).freeze();
                }
            }
            s.read_buf(&mut buf).await.unwrap();
        };

        // exit
        if query[0] == b'X' {
            break;
        }

        let query = &query
            .strip_prefix(b"Q")
            .expect("only handles simple queries")[4..];

        match query {
            b"select 1;\0" => {
                // row description: ?column?: int4
                s.write_all(&b"T\x00\x00\x00\x21\x00\x01?column?\0\x00\x00\x00\x00\x00\x00\x00\x00\x00\x17\x00\x04\x00\x00\x00\x00\x00\x00"[..]).await.unwrap();
                // row: [1]
                s.write_all(&b"D\x00\x00\x00\x0b\x00\x01\x00\x00\x00\x011"[..])
                    .await
                    .unwrap();
                // complete: SELECT 1
                s.write_all(&b"C\x00\x00\x00\x0dSELECT 1\0"[..])
                    .await
                    .unwrap();
            }
            b"select pg_sleep(5);\0" => {
                tokio::time::sleep(Duration::from_secs(5)).await;
                // empty response
                s.write_all(&b"I\x00\x00\x00\x04"[..]).await.unwrap();
            }
            _ => {
                // empty response
                s.write_all(&b"I\x00\x00\x00\x04"[..]).await.unwrap();
            }
        }
    }
}

async fn handshake(s: &mut TcpStream, mut buf: &mut BytesMut) {
    let _startup = loop {
        if buf.len() > 4 {
            let len = u32::from_be_bytes(buf[..4].try_into().unwrap()) as usize;
            if buf.len() >= len {
                break buf.split_to(len).freeze();
            }
        }
        s.read_buf(&mut buf).await.unwrap();
    };

    // we support only scram-sha-256 (since proxy will require it)
    s.write_all(&b"R\x00\x00\x00\x17\x00\x00\x00\x0aSCRAM-SHA-256\0\0"[..])
        .await
        .unwrap();

    // wait for client first message
    let auth_resp = loop {
        if buf.len() > 5 {
            let len = u32::from_be_bytes(buf[1..5].try_into().unwrap()) as usize + 1;
            if buf.len() >= len {
                break buf.split_to(len).freeze();
            }
        }
        s.read_buf(&mut buf).await.unwrap();
    };
    let salt = auth_resp
        .strip_prefix(&b"p\x00\x00\x00\x36SCRAM-SHA-256\0\x00\x00\x00\x20n,,n=,r="[..])
        .unwrap();

    // form server first message
    let mut server_first_message = BytesMut::new();
    server_first_message.extend_from_slice(&b"R\x00\x00\x00\x00\x00\x00\x00\x0br="[..]);
    server_first_message.extend_from_slice(salt);
    server_first_message.extend_from_slice(&[b'A'; 16]);
    server_first_message.extend_from_slice(&b",s=M2ZX/kfDSd3vv5iFO/QNUA==,i=4096"[..]);
    let len = ((server_first_message.len() - 1) as u32).to_be_bytes();
    server_first_message[1..5].copy_from_slice(&len);

    s.write_all(&server_first_message).await.unwrap();

    // wait for client final message. we don't care for the data because who needs authentication...
    let _auth_resp = loop {
        if buf.len() > 5 {
            let len = u32::from_be_bytes(buf[1..5].try_into().unwrap()) as usize + 1;
            if buf.len() >= len {
                break buf.split_to(len).freeze();
            }
        }
        s.read_buf(&mut buf).await.unwrap();
    };

    // server final message: proof for the client
    let server_key = b"\xde\x73\x22\xf1\xe0\x52\x1e\x08\x08\x04\xd4\xa0\x02\x29\x3a\x95\x09\xc4\xde\x14\x1c\xb1\x2f\xa6\xcb\x29\x59\x95\x88\x0d\x03\x55";
    let sig = Hmac::<sha2::Sha256>::new_from_slice(&server_key[..])
        .unwrap()
        .chain_update(b"n=,r=")
        .chain_update(salt)
        .chain_update(b",")
        .chain_update(&server_first_message[9..])
        .chain_update(b",")
        .chain_update(b"c=biws,r=")
        .chain_update(salt)
        .chain_update(b"AAAAAAAAAAAAAAAA")
        .finalize()
        .into_bytes();

    let mut sig64 = [0; 44];
    base64::encode_config_slice(sig, base64::STANDARD, &mut sig64);

    let mut server_final_message = BytesMut::new();
    server_final_message.extend_from_slice(&b"R\x00\x00\x00\x00\x00\x00\x00\x0cv="[..]);
    server_final_message.extend_from_slice(&sig64);
    let len = ((server_final_message.len() - 1) as u32).to_be_bytes();
    server_final_message[1..5].copy_from_slice(&len);

    s.write_all(&server_final_message).await.unwrap();

    // auth ok
    s.write_all(&b"R\x00\x00\x00\x08\x00\x00\x00\x00"[..])
        .await
        .unwrap();
}
