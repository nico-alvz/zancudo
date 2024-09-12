use lunatic::net::TcpListener;

fn main() -> std::io::Result<()> {
    let listener = TcpListener::bind("127.0.0.1:1883")?;
    println!("Servidor MQTT iniciado en {}", listener.local_addr()?);
    while let Ok((stream, _)) = listener.accept() {
        println!("Nuevo cliente conectado: {:?}", stream.peer_addr());
    }
    Ok(())
}
