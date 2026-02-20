use cpal::traits::{DeviceTrait, HostTrait};

fn main() {
    let host = cpal::default_host();

    println!("=== OUTPUT DEVICES ===");
    if let Ok(devices) = host.output_devices() {
        for d in devices {
            let name = d.name().unwrap_or_else(|_| "?".into());
            println!("  {name}");
        }
    }

    println!("\n=== INPUT DEVICES ===");
    if let Ok(devices) = host.input_devices() {
        for d in devices {
            let name = d.name().unwrap_or_else(|_| "?".into());
            println!("  {name}");
        }
    }
}
