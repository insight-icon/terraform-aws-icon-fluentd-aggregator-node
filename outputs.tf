output "private_ip" {
  value = aws_instance.this.private_ip
}

output "instance_id" {
  value = aws_instance.this.private_ip
}

output "fqdn" {
  value = aws_route53_record.a-record.fqdn
}