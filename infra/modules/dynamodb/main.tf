resource "aws_dynamodb_table" "items" {
  name         = "${var.name}-items"
  billing_mode = "PAY_PER_REQUEST" # 저트래픽에서 사실상 0원. 온디맨드는 쓰로틀이 거의 없어 "쓰로틀 자동복구" 시나리오는 제외
  hash_key     = "id"

  attribute {
    name = "id"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true # 데이터 수 KB 기준 월 1원 미만
  }
}
