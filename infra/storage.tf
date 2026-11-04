# Container registry for the agent image.
resource "aws_ecr_repository" "app" {
  name                 = "encoder-gpt-${var.environment}"
  image_tag_mutability = "IMMUTABLE" # a tag always means the same image -> reliable rollback

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the last 20 images"
      selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 20 }
      action       = { type = "expire" }
    }]
  })
}

# Retrieval index (ICD-10 embeddings). Reference data only — never PHI.
resource "aws_s3_bucket" "index" {
  bucket_prefix = "encoder-gpt-index-${var.environment}-"

  lifecycle {
    prevent_destroy = true # protect the knowledge base from an accidental destroy
  }
}

resource "aws_s3_bucket_versioning" "index" {
  bucket = aws_s3_bucket.index.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "index" {
  bucket = aws_s3_bucket.index.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "index" {
  bucket                  = aws_s3_bucket.index.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
