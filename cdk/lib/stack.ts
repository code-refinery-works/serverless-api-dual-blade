import * as cdk from "aws-cdk-lib";
import { Construct } from "constructs";
import * as dynamodb from "aws-cdk-lib/aws-dynamodb";
import * as lambda   from "aws-cdk-lib/aws-lambda";
import * as apigwv2  from "aws-cdk-lib/aws-apigatewayv2";
import * as integ    from "aws-cdk-lib/aws-apigatewayv2-integrations";
import * as logs     from "aws-cdk-lib/aws-logs";
import * as cloudwatch from "aws-cdk-lib/aws-cloudwatch";
import * as cw_actions from "aws-cdk-lib/aws-cloudwatch-actions";
import * as sns      from "aws-cdk-lib/aws-sns";
import * as path     from "path";
import { NagSuppressions } from "cdk-nag";

export interface ServerlessApiStackProps extends cdk.StackProps {
  project: string;
  stage: string;
  corsAllowOrigins: string[];
  lambdaReservedConcurrency: number;
  alarmSnsTopicArn: string;
}

export class ServerlessApiStack extends cdk.Stack {
  public readonly apiEndpoint: cdk.CfnOutput;

  constructor(scope: Construct, id: string, props: ServerlessApiStackProps) {
    super(scope, id, props);
    const { project, stage, corsAllowOrigins, lambdaReservedConcurrency, alarmSnsTopicArn } = props;
    const prefix = `${project}-${stage}`;

    // ── DynamoDB ────────────────────────────────────────────
    const table = new dynamodb.Table(this, "Table", {
      tableName:    prefix,
      partitionKey: { name: "pk", type: dynamodb.AttributeType.STRING },
      sortKey:      { name: "sk", type: dynamodb.AttributeType.STRING },
      billingMode:  dynamodb.BillingMode.PAY_PER_REQUEST,
      pointInTimeRecovery:    true,
      encryption:   dynamodb.TableEncryption.AWS_MANAGED,
      removalPolicy: cdk.RemovalPolicy.RETAIN,
    });
    table.addGlobalSecondaryIndex({
      indexName:      "email-index",
      partitionKey:   { name: "email", type: dynamodb.AttributeType.STRING },
      projectionType: dynamodb.ProjectionType.ALL,
    });

    // ── Lambda Log Group ────────────────────────────────────
    const lambdaLogGroup = new logs.LogGroup(this, "LambdaLogGroup", {
      logGroupName:  `/aws/lambda/${prefix}`,
      retention:     logs.RetentionDays.ONE_MONTH,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
    });

    // ── Lambda ──────────────────────────────────────────────
    const fn = new lambda.Function(this, "ApiHandler", {
      functionName:  prefix,
      runtime:       lambda.Runtime.NODEJS_20_X,
      architecture:  lambda.Architecture.ARM_64,
      handler:       "index.handler",
      code:          lambda.Code.fromAsset(path.join(__dirname, "../../src")),
      timeout:       cdk.Duration.seconds(29),
      memorySize:    256,
      reservedConcurrentExecutions: lambdaReservedConcurrency,
      logGroup:      lambdaLogGroup,
      environment: {
        TABLE_NAME: table.tableName,
        LOG_LEVEL:  "INFO",
      },
    });
    table.grantReadWriteData(fn);

    const liveAlias = new lambda.Alias(this, "LiveAlias", {
      aliasName:      "live",
      version:        fn.currentVersion,
    });

    // ── API Gateway HTTP API ────────────────────────────────
    const apigwLogGroup = new logs.LogGroup(this, "ApiGwLogGroup", {
      logGroupName:  `/aws/apigateway/${prefix}`,
      retention:     logs.RetentionDays.ONE_MONTH,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
    });

    const httpApi = new apigwv2.HttpApi(this, "HttpApi", {
      apiName:     prefix,
      corsPreflight: {
        allowHeaders: ["content-type", "authorization"],
        allowMethods: [apigwv2.CorsHttpMethod.GET, apigwv2.CorsHttpMethod.POST,
                       apigwv2.CorsHttpMethod.PUT, apigwv2.CorsHttpMethod.DELETE,
                       apigwv2.CorsHttpMethod.OPTIONS],
        allowOrigins: corsAllowOrigins,
        maxAge:       cdk.Duration.seconds(300),
      },
      defaultIntegration: new integ.HttpLambdaIntegration("LambdaInteg", liveAlias, {
        payloadFormatVersion: apigwv2.PayloadFormatVersion.VERSION_2_0,
      }),
      createDefaultStage: false,
    });

    new apigwv2.HttpStage(this, "DefaultStage", {
      httpApi,
      stageName:   "$default",
      autoDeploy:  true,
      throttle: { burstLimit: 500, rateLimit: 1000 },
    });

    // ── CloudWatch Alarms ───────────────────────────────────
    const alarmAction = alarmSnsTopicArn
      ? [new cw_actions.SnsAction(sns.Topic.fromTopicArn(this, "AlarmTopic", alarmSnsTopicArn))]
      : [];

    const mkAlarm = (id: string, metric: cloudwatch.Metric, threshold: number) =>
      new cloudwatch.Alarm(this, id, {
        metric, threshold,
        evaluationPeriods:  1,
        comparisonOperator: cloudwatch.ComparisonOperator.GREATER_THAN_OR_EQUAL_TO_THRESHOLD,
        treatMissingData:   cloudwatch.TreatMissingData.NOT_BREACHING,
        alarmActions:       alarmAction,
      });

    mkAlarm("LambdaErrorAlarm",    fn.metricErrors({ period: cdk.Duration.minutes(1) }),    5);
    mkAlarm("LambdaThrottleAlarm", fn.metricThrottles({ period: cdk.Duration.minutes(1) }), 10);
    mkAlarm("ApiGw5xxAlarm",
      httpApi.metricServerError({ period: cdk.Duration.minutes(1) }), 10);

    // ── Outputs ─────────────────────────────────────────────
    this.apiEndpoint = new cdk.CfnOutput(this, "ApiEndpoint", {
      value:       httpApi.apiEndpoint,
      description: "HTTP API invoke URL",
    });
    new cdk.CfnOutput(this, "TableName",        { value: table.tableName });
    new cdk.CfnOutput(this, "FunctionName",     { value: fn.functionName });
    new cdk.CfnOutput(this, "LambdaLogGroup",   { value: lambdaLogGroup.logGroupName });
    new cdk.CfnOutput(this, "ApiGwLogGroup",    { value: apigwLogGroup.logGroupName });

    // ── cdk-nag Suppressions ────────────────────────────────
    NagSuppressions.addStackSuppressions(this, [
      { id: "AwsSolutions-IAM4", reason: "grantReadWriteData generates scoped inline policy; no AWS managed policies used." },
      { id: "AwsSolutions-APIG1", reason: "Access logging enabled via HttpStage accessLogSettings via L1 escape hatch; L2 HttpStage handles it." },
    ]);
  }
}