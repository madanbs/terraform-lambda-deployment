terraform {
  required_version = "~> 1.0"
}

provider "aws" {
  region = var.aws_region
}

resource "random_pet" "bucket" {
  length    = 3
  separator = "-"
}

# pipeline
module "artifact" {
  source        = "aws//modules/s3"
  version       = "0.2.0"
  name          = random_pet.bucket.id
  tags          = var.tags
  force_destroy = true
}

resource "aws_iam_policy" "github" {
  name        = join("-", [var.name, "gh-conn"])
  description = "Allows to run code build"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        "Effect"   = "Allow"
        "Action"   = ["codestar-connections:UseConnection"]
        "Resource" = aws_codestarconnections_connection.github.arn
      },
    ]
  })
}

resource "aws_codestarconnections_connection" "github" {
  name          = join("-", [var.name, "gh-conn"])
  provider_type = "GitHub"
}

module "pipeline" {
  source  = "aws//modules/pipeline"
  version = "0.2.1"
  name    = var.name
  tags    = var.tags
  policy_arns = [
    aws_iam_policy.github.arn,
    module.artifact.policy_arns.write,
  ]
  artifact_config = [{
    location = module.artifact.bucket.id
    type     = "S3"
  }]
  stage_config = [
    {
      name = "Source"
      actions = [{
        name             = "Source"
        category         = "Source"
        owner            = "AWS"
        provider         = "CodeStarSourceConnection"
        version          = "1"
        output_artifacts = ["source_output"]
        run_order        = 1
        configuration = {
          ConnectionArn    = aws_codestarconnections_connection.github.arn
          FullRepositoryId = "madanbs/terraform-lambda-deployment"
          BranchName       = "main"
        }
      }]
    },
    {
      name = "Build"
      actions = [{
        name             = "Build"
        category         = "Build"
        owner            = "AWS"
        provider         = "CodeBuild"
        version          = "1"
        input_artifacts  = ["source_output"]
        output_artifacts = ["build_output"]
        run_order        = 2
        configuration = {
          ProjectName = module.build.project.name
        }
      }]
    },
    {
      name = "Deploy"
      actions = [{
        name             = "Deploy"
        category         = "Build"
        owner            = "AWS"
        provider         = "CodeBuild"
        version          = "1"
        input_artifacts  = ["source_output"]
        output_artifacts = ["deploy_output"]
        run_order        = 3
        configuration = {
          ProjectName = module.deploy.project.name
        }
      }]
    },
  ]
}

module "build" {
  source      = "aws//modules/codebuild"
  version     = "2.3.1"
  name        = var.name
  tags        = var.tags
  policy_arns = [module.artifact.policy_arns.write]
  project = {
    environment = {
      image           = "aws/codebuild/standard:4.0"
      privileged_mode = true
      environment_variables = {
        WORKDIR         = "pipeline/app"
        PKG             = "lambda_handler.zip"
        ARTIFACT_BUCKET = module.artifact.bucket.id
      }
    }
    source = {
      type      = "GITHUB"
      location  = "https://github.com/madanbs/terraform-lambda-deployment.git"
      buildspec = "pipeline/app/buildspec/build.yaml"
      version   = "main"
    }
  }
}

module "deploy" {
  source      = "aws//modules/codebuild"
  version     = "2.3.1"
  name        = var.name
  tags        = var.tags
  policy_arns = ["arn:aws:iam::aws:policy/AdministratorAccess"]
  project = {
    environment = {
      image = "hashicorp/terraform"
      environment_variables = {
        WORKDIR         = "pipeline/app"
        ARTIFACT_BUCKET = module.artifact.bucket.id
      }
    }
    source = {
      type      = "GITHUB"
      location  = "https://github.com/madanbs/terraform-lambda-deployment.git"
      buildspec = "pipeline/app/buildspec/deploy.yaml"
      version   = "main"
    }
  }
}

# cloudwatch logs
module "logs" {
  source    = "madan/lambda/aws//modules/logs"
  version   = "0.2.1"
  name      = var.name
  log_group = var.log_config
}
