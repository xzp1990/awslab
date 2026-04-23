REGION="eu-south-2"
CLUSTER_NAME="ocr-server"
INSTANCE_GROUP="g6e-b"
INSTANCE_TYPE="ml.g6e.2xlarge"
TARGET_COUNT=1
EXECUTION_ROLE="arn:aws:iam::0000000000:role/admin-hp"
LIFECYCLE_S3_URI="s3://sagemaker-hp-koala-1-957af85c-bucket"
LIFECYCLE_SCRIPT="on_create.sh"
THREADS_PER_CORE=2
EBS_VOLUME_SIZE=500

aws sagemaker update-cluster \
        --region $REGION \
        --cluster-name $CLUSTER_NAME \
        --instance-groups '[
          {
            "InstanceGroupName": "'$INSTANCE_GROUP'",
            "InstanceType": "'$INSTANCE_TYPE'",
            "InstanceCount": '$TARGET_COUNT',
            "ExecutionRole": "'$EXECUTION_ROLE'",
            "LifeCycleConfig": {
              "SourceS3Uri": "'$LIFECYCLE_S3_URI'",
              "OnCreate": "'$LIFECYCLE_SCRIPT'"
            },
            "ThreadsPerCore": '$THREADS_PER_CORE',
            "TrainingPlanArn": "'$TRAINING_PLAN_ARN'",
            "InstanceStorageConfigs": [
              {
                "EbsVolumeConfig": {
                  "VolumeSizeInGB": '$EBS_VOLUME_SIZE'
                }
              }
            ],
            "OverrideVpcConfig": {
                "SecurityGroupIds": [
                    "sg-01f29004a940d1e29"
                ],
                "Subnets": [
                    "subnet-083c660fc60710c5f"
                ]
            }
          }
        ]'
