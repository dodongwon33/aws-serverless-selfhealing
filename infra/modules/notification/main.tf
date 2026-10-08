# SSE를 켜지 않는 이유: CloudWatch 알람은 AWS 관리형 키(aws/sns)로 암호화된 토픽에 발행할 수 없고,
# 고객 관리형 KMS 키는 월 $1이라 예산 대비 과하다. 토픽에는 알람 메타데이터만 흐른다.
resource "aws_sns_topic" "alerts" {
  name = "${var.name}-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email # 수신 메일의 Confirm 링크를 눌러야 활성화된다
}
