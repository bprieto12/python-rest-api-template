# Provisioned capacity, not on-demand — DynamoDB's free tier (25 WCU + 25
# RCU + 25GB storage) is *perpetual* but only applies to provisioned mode.
# 5/5 per table (10/10 combined across both) leaves headroom under that
# ceiling. If traffic ever approaches these numbers, add Application Auto
# Scaling (aws_appautoscaling_target/policy) rather than hand-raising the
# numbers — not added preemptively for a low-traffic mock catalogue.
#
# See ../src/books_api/repository.py's module docstring for why there are
# two tables (the isbns one exists purely to enforce ISBN uniqueness).

resource "aws_dynamodb_table" "books" {
  name           = "books-api-books"
  billing_mode   = "PROVISIONED"
  read_capacity  = 5
  write_capacity = 5
  hash_key       = "id"

  attribute {
    name = "id"
    type = "N"
  }

  # Continuous backups, restorable to any point in the last 35 days — the
  # only thing standing between "someone fat-fingers a delete" and "that
  # data's just gone." An in-place-updatable attribute, not a table
  # replacement, so this is free to turn on after the fact.
  point_in_time_recovery {
    enabled = true
  }
}

resource "aws_dynamodb_table" "isbns" {
  name           = "books-api-isbns"
  billing_mode   = "PROVISIONED"
  read_capacity  = 5
  write_capacity = 5
  hash_key       = "isbn"

  attribute {
    name = "isbn"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }
}
