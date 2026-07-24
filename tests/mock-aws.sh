#!/bin/bash
# Deterministic AWS CLI stand-in for operator workflow tests.
set -euo pipefail

service=${1:-}
operation=${2:-}

case "${service}:${operation}" in
  sts:get-caller-identity)
    printf '%s\n' \
      '{"UserId":"TEST","Account":"123456789012","Arn":"arn:aws:iam::123456789012:user/operator"}'
    ;;
  s3api:get-bucket-location)
    printf '{"LocationConstraint":"%s"}\n' \
      "${MOCK_BUCKET_REGION:-us-west-2}"
    ;;
  s3api:put-bucket-ownership-controls | \
    s3api:put-public-access-block | \
    s3api:put-bucket-encryption | \
    s3api:put-bucket-versioning | \
    s3api:put-bucket-lifecycle-configuration | \
    s3api:put-bucket-policy)
    printf '%s\n' '{}'
    ;;
  s3api:get-bucket-ownership-controls)
    printf '%s\n' \
      '{"OwnershipControls":{"Rules":[{"ObjectOwnership":"BucketOwnerEnforced"}]}}'
    ;;
  s3api:get-public-access-block)
    printf '%s\n' \
      '{"PublicAccessBlockConfiguration":{"BlockPublicAcls":true,"IgnorePublicAcls":true,"BlockPublicPolicy":true,"RestrictPublicBuckets":true}}'
    ;;
  s3api:get-bucket-encryption)
    printf '%s\n' \
      '{"ServerSideEncryptionConfiguration":{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}}'
    ;;
  s3api:get-bucket-versioning)
    printf '%s\n' '{"Status":"Enabled"}'
    ;;
  s3api:get-bucket-lifecycle-configuration)
    printf '%s\n' \
      '{"Rules":[{"ID":"chatto-backup-retention","Status":"Enabled","Filter":{"Prefix":"chatto/backups/"},"Expiration":{"Days":14},"NoncurrentVersionExpiration":{"NoncurrentDays":14},"AbortIncompleteMultipartUpload":{"DaysAfterInitiation":1}}]}'
    ;;
  s3api:get-bucket-policy)
    printf '%s\n' \
      '{"Statement":[{"Sid":"DenyInsecureTransport","Effect":"Deny","Condition":{"Bool":{"aws:SecureTransport":"false"}}}]}'
    ;;
  s3api:get-bucket-policy-status)
    printf '%s\n' '{"PolicyStatus":{"IsPublic":false}}'
    ;;
  sns:create-topic)
    printf '%s\n' \
      'arn:aws:sns:us-west-2:123456789012:chatto-operations'
    ;;
  sns:list-subscriptions-by-topic)
    if [ "${MOCK_SUBSCRIPTION_PENDING:-0}" = 1 ]; then
      printf '%s\n' \
        '{"Subscriptions":[{"SubscriptionArn":"PendingConfirmation","Protocol":"email","Endpoint":"operator@example.com","TopicArn":"arn:aws:sns:us-west-2:123456789012:chatto-operations"}]}'
    else
      printf '%s\n' \
        '{"Subscriptions":[{"SubscriptionArn":"arn:aws:sns:us-west-2:123456789012:chatto-operations:confirmed","Protocol":"email","Endpoint":"operator@example.com","TopicArn":"arn:aws:sns:us-west-2:123456789012:chatto-operations"}]}'
    fi
    ;;
  sesv2:get-email-identity)
    if [ -n "${MOCK_SES_STATE_FILE:-}" ] &&
      [ ! -f "${MOCK_SES_STATE_FILE}" ]; then
      exit 254
    fi
    if [ "${MOCK_SES_PENDING:-0}" = 1 ]; then
      printf '%s\n' \
        '{"IdentityType":"DOMAIN","VerifiedForSendingStatus":false,"DkimAttributes":{"SigningEnabled":true,"Status":"PENDING","Tokens":["dkimtoken1","dkimtoken2","dkimtoken3"],"SigningHostedZone":"dkim.amazonses.com"}}'
    else
      printf '%s\n' \
        '{"IdentityType":"DOMAIN","VerifiedForSendingStatus":true,"DkimAttributes":{"SigningEnabled":true,"Status":"SUCCESS","Tokens":["dkimtoken1","dkimtoken2","dkimtoken3"],"SigningHostedZone":"dkim.amazonses.com"}}'
    fi
    ;;
  sesv2:create-email-identity)
    if [ -n "${MOCK_SES_STATE_FILE:-}" ]; then
      : > "${MOCK_SES_STATE_FILE}"
    fi
    printf '%s\n' \
      '{"IdentityType":"DOMAIN","VerifiedForSendingStatus":false,"DkimAttributes":{"SigningEnabled":true,"Status":"PENDING","Tokens":["dkimtoken1","dkimtoken2","dkimtoken3"],"SigningHostedZone":"dkim.amazonses.com"}}'
    ;;
  sesv2:get-account)
    if [ "${MOCK_SES_SANDBOX:-0}" = 1 ]; then
      printf '%s\n' \
        '{"SendingEnabled":true,"ProductionAccessEnabled":false}'
    else
      printf '%s\n' \
        '{"SendingEnabled":true,"ProductionAccessEnabled":true}'
    fi
    ;;
  sesv2:put-email-identity-dkim-attributes)
    printf '%s\n' '{}'
    ;;
  iam:get-user)
    if [[ " $* " == *" --user-name chatto-smtp "* ]]; then
      printf '%s\n' \
        '{"User":{"Path":"/","UserName":"chatto-smtp","UserId":"SMTPTEST","Arn":"arn:aws:iam::123456789012:user/chatto-smtp"}}'
    else
      printf '%s\n' \
        '{"User":{"Path":"/","UserName":"chatto-backup","UserId":"TEST","Arn":"arn:aws:iam::123456789012:user/chatto-backup"}}'
    fi
    ;;
  iam:get-login-profile)
    exit 254
    ;;
  iam:list-attached-user-policies)
    printf '%s\n' '{"AttachedPolicies":[]}'
    ;;
  iam:list-groups-for-user)
    if [[ " $* " == *" --user-name chatto-smtp "* ]] &&
      [ "${MOCK_SMTP_GROUP:-0}" = 1 ]; then
      printf '%s\n' \
        '{"Groups":[{"Path":"/","GroupName":"unexpected","GroupId":"GROUP","Arn":"arn:aws:iam::123456789012:group/unexpected"}]}'
    else
      printf '%s\n' '{"Groups":[]}'
    fi
    ;;
  iam:list-user-policies)
    printf '%s\n' '{"PolicyNames":[]}'
    ;;
  iam:put-user-policy)
    printf '%s\n' '{}'
    ;;
  iam:get-user-policy)
    # get-user-policy does not receive the source file, so reproduce the
    # deterministic document assembled by provision-aws.sh.
    if [[ " $* " == *" --user-name chatto-smtp "* ]]; then
      printf '%s\n' \
        '{"PolicyName":"ChattoSESSend","PolicyDocument":{"Version":"2012-10-17","Statement":[{"Sid":"SendChattoTransactionalEmail","Effect":"Allow","Action":"ses:SendRawEmail","Resource":"arn:aws:ses:us-west-2:123456789012:identity/jessedc.dev","Condition":{"StringEquals":{"ses:FromAddress":"noreply@jessedc.dev"}}}]}}'
    else
      printf '%s\n' \
        '{"PolicyName":"ChattoBackupAndAlerts","PolicyDocument":{"Version":"2012-10-17","Statement":[{"Sid":"InspectBucket","Effect":"Allow","Action":"s3:GetBucketLocation","Resource":"arn:aws:s3:::chatto-test-example-bucket"},{"Sid":"ListBackupPrefix","Effect":"Allow","Action":"s3:ListBucket","Resource":"arn:aws:s3:::chatto-test-example-bucket","Condition":{"StringLike":{"s3:prefix":["chatto/backups","chatto/backups/*"]}}},{"Sid":"UseBackupObjects","Effect":"Allow","Action":["s3:PutObject","s3:GetObject","s3:AbortMultipartUpload","s3:ListMultipartUploadParts"],"Resource":"arn:aws:s3:::chatto-test-example-bucket/chatto/backups/*"},{"Sid":"PublishOperationsAlerts","Effect":"Allow","Action":"sns:Publish","Resource":"arn:aws:sns:us-west-2:123456789012:chatto-operations"}]}}'
    fi
    ;;
  iam:list-access-keys)
    if [[ " $* " == *" --user-name chatto-smtp "* ]] &&
      [ "${MOCK_SMTP_ACCESS_KEY_EXISTS:-0}" = 1 ]; then
      printf '%s\n' \
        '{"AccessKeyMetadata":[{"UserName":"chatto-smtp","AccessKeyId":"AKIAFEDCBA0987654321","Status":"Active"}]}'
    elif [[ " $* " != *" --user-name chatto-smtp "* ]] &&
      [ "${MOCK_ACCESS_KEY_EXISTS:-0}" = 1 ]; then
      printf '%s\n' \
        '{"AccessKeyMetadata":[{"UserName":"chatto-backup","AccessKeyId":"AKIA1234567890ABCDEF","Status":"Active"}]}'
    else
      printf '%s\n' '{"AccessKeyMetadata":[]}'
    fi
    ;;
  iam:create-access-key)
    if [[ " $* " == *" --user-name chatto-smtp "* ]]; then
      printf '%s\n' \
        '{"AccessKey":{"UserName":"chatto-smtp","AccessKeyId":"AKIAFEDCBA0987654321","Status":"Active","SecretAccessKey":"0123456789012345678901234567890123456789"}}'
    else
      printf '%s\n' \
        '{"AccessKey":{"UserName":"chatto-backup","AccessKeyId":"AKIA1234567890ABCDEF","Status":"Active","SecretAccessKey":"0123456789012345678901234567890123456789"}}'
    fi
    ;;
  iam:delete-access-key)
    printf '%s\n' '{}'
    ;;
  *)
    printf 'unexpected mock AWS call: %s %s\n' "${service}" "${operation}" >&2
    exit 1
    ;;
esac
