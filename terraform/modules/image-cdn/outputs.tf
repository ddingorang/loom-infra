output "bucket_name" {
  value = aws_s3_bucket.images.id
}

output "bucket_arn" {
  value = aws_s3_bucket.images.arn
}

output "distribution_id" {
  value = aws_cloudfront_distribution.images.id
}

output "distribution_domain_name" {
  value = aws_cloudfront_distribution.images.domain_name
}
