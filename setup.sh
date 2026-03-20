#!/bin/bash
set -e

REPO_URL="https://@github.com/naveensy/aws-schd-app.git"
BRANCH="develop"

echo "📦 Cloning repo..."
git clone "$REPO_URL" aws-schd-app
cd aws-schd-app

echo "🌿 Creating branch $BRANCH..."
git checkout -b $BRANCH 2>/dev/null || git checkout $BRANCH

# ── Create folders ────────────────────────────────────────────
mkdir -p layers/common/python
mkdir -p functions/resources
mkdir -p functions/schedules
mkdir -p functions/audit
mkdir -p functions/users
mkdir -p functions/costs
mkdir -p scripts
mkdir -p .github/workflows

# ── .gitignore ───────────────────────────────────────────────
cat > .gitignore << 'EOF'
__pycache__/
*.pyc
.aws-sam/
.env
samconfig.toml
EOF

# ── requirements.txt ─────────────────────────────────────────
cat > requirements.txt << 'EOF'
boto3>=1.34.0
pydantic>=2.0.0
azure-identity>=1.15.0
azure-mgmt-compute>=30.0.0
azure-mgmt-sql>=3.0.0
EOF

# ── template.yaml ────────────────────────────────────────────
cat > template.yaml << 'EOF'
AWSTemplateFormatVersion: '2010-09-09'
Transform: AWS::Serverless-2016-10-31
Description: CloudScheduler — Serverless AWS/Azure Resource Scheduler

Globals:
  Function:
    Runtime: python3.12
    Timeout: 30
    MemorySize: 256
    Environment:
      Variables:
        TABLE_NAME: !Ref SchedulerTable
        AUDIT_TABLE: !Ref AuditTable
        COGNITO_USER_POOL_ID: !Ref CognitoUserPool
        COGNITO_CLIENT_ID: !Ref CognitoUserPoolClient
        SLACK_WEBHOOK_URL: !Sub '{{resolve:ssm:/cloudscheduler/slack_webhook}}'
        SES_FROM_EMAIL: !Sub '{{resolve:ssm:/cloudscheduler/ses_from_email}}'
        AZURE_TENANT_ID: !Sub '{{resolve:ssm:/cloudscheduler/azure_tenant_id}}'
        AZURE_CLIENT_ID: !Sub '{{resolve:ssm:/cloudscheduler/azure_client_id}}'
        AZURE_CLIENT_SECRET: !Sub '{{resolve:ssm:/cloudscheduler/azure_client_secret}}'
    Layers:
      - !Ref CommonLayer
    Tracing: Active

Parameters:
  Environment:
    Type: String
    Default: dev
    AllowedValues: [dev, staging, prod]

Resources:
  CognitoUserPool:
    Type: AWS::Cognito::UserPool
    Properties:
      UserPoolName: !Sub 'cloudscheduler-${Environment}'
      AutoVerifiedAttributes: [email]
      UsernameAttributes: [email]
      Policies:
        PasswordPolicy:
          MinimumLength: 8
          RequireUppercase: true
          RequireNumbers: true
          RequireSymbols: false

  CognitoUserPoolClient:
    Type: AWS::Cognito::UserPoolClient
    Properties:
      ClientName: !Sub 'cloudscheduler-client-${Environment}'
      UserPoolId: !Ref CognitoUserPool
      GenerateSecret: false
      ExplicitAuthFlows:
        - ALLOW_USER_PASSWORD_AUTH
        - ALLOW_REFRESH_TOKEN_AUTH
        - ALLOW_USER_SRP_AUTH

  CognitoAdminGroup:
    Type: AWS::Cognito::UserPoolGroup
    Properties:
      GroupName: Admin
      UserPoolId: !Ref CognitoUserPool

  CognitoDevOpsGroup:
    Type: AWS::Cognito::UserPoolGroup
    Properties:
      GroupName: DevOps
      UserPoolId: !Ref CognitoUserPool

  CognitoDeveloperGroup:
    Type: AWS::Cognito::UserPoolGroup
    Properties:
      GroupName: Developer
      UserPoolId: !Ref CognitoUserPool

  SchedulerTable:
    Type: AWS::DynamoDB::Table
    Properties:
      TableName: !Sub 'cloudscheduler-resources-${Environment}'
      BillingMode: PAY_PER_REQUEST
      AttributeDefinitions:
        - AttributeName: PK
          AttributeType: S
        - AttributeName: SK
          AttributeType: S
        - AttributeName: cloud
          AttributeType: S
        - AttributeName: status
          AttributeType: S
      KeySchema:
        - AttributeName: PK
          KeyType: HASH
        - AttributeName: SK
          KeyType: RANGE
      GlobalSecondaryIndexes:
        - IndexName: cloud-index
          KeySchema:
            - AttributeName: cloud
              KeyType: HASH
            - AttributeName: SK
              KeyType: RANGE
          Projection:
            ProjectionType: ALL
        - IndexName: status-index
          KeySchema:
            - AttributeName: status
              KeyType: HASH
            - AttributeName: SK
              KeyType: RANGE
          Projection:
            ProjectionType: ALL

  AuditTable:
    Type: AWS::DynamoDB::Table
    Properties:
      TableName: !Sub 'cloudscheduler-audit-${Environment}'
      BillingMode: PAY_PER_REQUEST
      AttributeDefinitions:
        - AttributeName: PK
          AttributeType: S
        - AttributeName: SK
          AttributeType: S
      KeySchema:
        - AttributeName: PK
          KeyType: HASH
        - AttributeName: SK
          KeyType: RANGE
      TimeToLiveSpecification:
        AttributeName: ttl
        Enabled: true

  ApiGateway:
    Type: AWS::Serverless::Api
    Properties:
      Name: !Sub 'cloudscheduler-api-${Environment}'
      StageName: !Ref Environment
      Cors:
        AllowMethods: "'GET,POST,PUT,DELETE,OPTIONS'"
        AllowHeaders: "'Content-Type,Authorization'"
        AllowOrigin: "'*'"
      Auth:
        DefaultAuthorizer: CognitoAuthorizer
        Authorizers:
          CognitoAuthorizer:
            UserPoolArn: !GetAtt CognitoUserPool.Arn
            Identity:
              Header: Authorization

  CommonLayer:
    Type: AWS::Serverless::LayerVersion
    Properties:
      LayerName: !Sub 'cloudscheduler-common-${Environment}'
      ContentUri: layers/common/
      CompatibleRuntimes: [python3.12]
    Metadata:
      BuildMethod: python3.12

  ListResourcesFunction:
    Type: AWS::Serverless::Function
    Properties:
      CodeUri: functions/resources/
      Handler: list.handler
      Policies: [DynamoDBReadPolicy: {TableName: !Ref SchedulerTable}]
      Events:
        Api:
          Type: Api
          Properties:
            RestApiId: !Ref ApiGateway
            Path: /resources
            Method: GET

  CreateResourceFunction:
    Type: AWS::Serverless::Function
    Properties:
      CodeUri: functions/resources/
      Handler: create.handler
      Policies:
        - DynamoDBWritePolicy: {TableName: !Ref SchedulerTable}
        - DynamoDBWritePolicy: {TableName: !Ref AuditTable}
      Events:
        Api:
          Type: Api
          Properties:
            RestApiId: !Ref ApiGateway
            Path: /resources
            Method: POST

  UpdateResourceFunction:
    Type: AWS::Serverless::Function
    Properties:
      CodeUri: functions/resources/
      Handler: update.handler
      Policies:
        - DynamoDBCrudPolicy: {TableName: !Ref SchedulerTable}
        - DynamoDBWritePolicy: {TableName: !Ref AuditTable}
      Events:
        Api:
          Type: Api
          Properties:
            RestApiId: !Ref ApiGateway
            Path: /resources/{id}
            Method: PUT

  DeleteResourceFunction:
    Type: AWS::Serverless::Function
    Properties:
      CodeUri: functions/resources/
      Handler: delete.handler
      Policies:
        - DynamoDBCrudPolicy: {TableName: !Ref SchedulerTable}
        - DynamoDBWritePolicy: {TableName: !Ref AuditTable}
      Events:
        Api:
          Type: Api
          Properties:
            RestApiId: !Ref ApiGateway
            Path: /resources/{id}
            Method: DELETE

  OverrideFunction:
    Type: AWS::Serverless::Function
    Properties:
      CodeUri: functions/schedules/
      Handler: override.handler
      Policies:
        - DynamoDBCrudPolicy: {TableName: !Ref SchedulerTable}
        - DynamoDBWritePolicy: {TableName: !Ref AuditTable}
      Events:
        Api:
          Type: Api
          Properties:
            RestApiId: !Ref ApiGateway
            Path: /resources/{id}/override
            Method: POST
        DeleteOverride:
          Type: Api
          Properties:
            RestApiId: !Ref ApiGateway
            Path: /resources/{id}/override/{override_id}
            Method: DELETE

  ApplyScheduleFunction:
    Type: AWS::Serverless::Function
    Properties:
      CodeUri: functions/schedules/
      Handler: apply.handler
      Timeout: 300
      MemorySize: 512
      Policies:
        - DynamoDBCrudPolicy: {TableName: !Ref SchedulerTable}
        - DynamoDBWritePolicy: {TableName: !Ref AuditTable}
        - Statement:
            - Effect: Allow
              Action:
                - ec2:StartInstances
                - ec2:StopInstances
                - rds:StartDBInstance
                - rds:StopDBInstance
              Resource: "*"
      Events:
        ScheduleTrigger:
          Type: Schedule
          Properties:
            Schedule: rate(5 minutes)
            Enabled: true

  ListAuditFunction:
    Type: AWS::Serverless::Function
    Properties:
      CodeUri: functions/audit/
      Handler: list.handler
      Policies: [DynamoDBReadPolicy: {TableName: !Ref AuditTable}]
      Events:
        Api:
          Type: Api
          Properties:
            RestApiId: !Ref ApiGateway
            Path: /audit
            Method: GET

  ListUsersFunction:
    Type: AWS::Serverless::Function
    Properties:
      CodeUri: functions/users/
      Handler: list.handler
      Policies:
        - Statement:
            - Effect: Allow
              Action: [cognito-idp:ListUsers, cognito-idp:ListUsersInGroup]
              Resource: !GetAtt CognitoUserPool.Arn
      Events:
        Api:
          Type: Api
          Properties:
            RestApiId: !Ref ApiGateway
            Path: /users
            Method: GET

  UpdateUserRoleFunction:
    Type: AWS::Serverless::Function
    Properties:
      CodeUri: functions/users/
      Handler: update_role.handler
      Policies:
        - Statement:
            - Effect: Allow
              Action:
                - cognito-idp:AdminAddUserToGroup
                - cognito-idp:AdminRemoveUserFromGroup
              Resource: !GetAtt CognitoUserPool.Arn
      Events:
        Api:
          Type: Api
          Properties:
            RestApiId: !Ref ApiGateway
            Path: /users/{id}/role
            Method: PUT

  CostEstimateFunction:
    Type: AWS::Serverless::Function
    Properties:
      CodeUri: functions/costs/
      Handler: estimate.handler
      Policies: [DynamoDBReadPolicy: {TableName: !Ref SchedulerTable}]
      Events:
        Api:
          Type: Api
          Properties:
            RestApiId: !Ref ApiGateway
            Path: /costs/estimate
            Method: GET

Outputs:
  ApiUrl:
    Value: !Sub 'https://${ApiGateway}.execute-api.${AWS::Region}.amazonaws.com/${Environment}'
  UserPoolId:
    Value: !Ref CognitoUserPool
  UserPoolClientId:
    Value: !Ref CognitoUserPoolClient
EOF

# ── layers/common/python/dynamo.py ───────────────────────────
cat > layers/common/python/dynamo.py << 'EOF'
import os, boto3, uuid
from datetime import datetime, timezone
from boto3.dynamodb.conditions import Key

dynamodb    = boto3.resource("dynamodb")
TABLE       = os.environ["TABLE_NAME"]
AUDIT_TABLE = os.environ["AUDIT_TABLE"]

def get_table():       return dynamodb.Table(TABLE)
def get_audit_table(): return dynamodb.Table(AUDIT_TABLE)
def now_iso():         return datetime.now(timezone.utc).isoformat()

def write_audit(user, action, resource_name, detail, resource_id=""):
    tbl = get_audit_table()
    ts  = now_iso()
    ttl = int(datetime.now(timezone.utc).timestamp()) + (90 * 86400)
    tbl.put_item(Item={
        "PK": f
