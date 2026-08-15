output "instance_name" {
  description = "Name of the co-located Lightsail staging instance."
  value       = aws_lightsail_instance.staging.name
}

output "static_ip" {
  description = "Static IPv4 address for staging DNS and --resolve checks."
  value       = aws_lightsail_static_ip.staging.ip_address
}
