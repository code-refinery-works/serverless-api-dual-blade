#!/usr/bin/env node
import "source-map-support/register";
import * as cdk from "aws-cdk-lib";
import { Aspects } from "aws-cdk-lib";
import { AwsSolutionsChecks } from "cdk-nag";
import { ServerlessApiStack } from "../lib/stack";

const app = new cdk.App();

const stack = new ServerlessApiStack(app, "ServerlessApiStack", {
  env: {
    account: process.env.CDK_DEFAULT_ACCOUNT,
    region: process.env.CDK_DEFAULT_REGION ?? "ap-northeast-1",
  },
  project: app.node.tryGetContext("project") ?? "serverless-api",
  stage:   app.node.tryGetContext("stage")   ?? "prod",
  corsAllowOrigins:        app.node.tryGetContext("corsOrigins")?.split(",") ?? ["https://example.com"],
  lambdaReservedConcurrency: Number(app.node.tryGetContext("reservedConcurrency") ?? 100),
  alarmSnsTopicArn:        app.node.tryGetContext("alarmSnsTopicArn") ?? "",
});

Aspects.of(app).add(new AwsSolutionsChecks({ verbose: true }));

cdk.Tags.of(stack).add("Project", stack.node.tryGetContext("project") ?? "serverless-api");
cdk.Tags.of(stack).add("Env",     stack.node.tryGetContext("stage")   ?? "prod");