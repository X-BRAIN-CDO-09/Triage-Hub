import json
import os
import time

import boto3


def run_demo():
    print("=================================================================")
    print("STARTING CDO REAL-WORLD INCIDENT DATASET TRIGGER VIA SQS")
    print("=================================================================\n")

    # 1. Định vị đường dẫn file JSON
    dataset_path = os.path.join(os.path.dirname(__file__), "demo_dataset.json")
    if not os.path.exists(dataset_path):
        print(f"Error: Khong tim thay file JSON {dataset_path}")
        return

    with open(dataset_path, "r", encoding="utf-8") as f:
        dataset = json.load(f)

    # 2. Định nghĩa SQS Buffer Queue URL của Sandbox
    buffer_queue_url = "https://sqs.us-east-1.amazonaws.com/730335441285/triage-hub-buffer-queue"
    print(f"Target Queue: {buffer_queue_url}")

    # 3. Tạo SQS Client sử dụng AWS credentials local của bạn
    try:
        sqs_client = boto3.client("sqs", region_name="us-east-1")
    except Exception as e:
        print(f"Error SQS Client: {e}")
        return

    # 4. Lần lượt gửi từng sự cố vào SQS Buffer Queue
    for idx, case in enumerate(dataset, 1):
        print(f"\nSending incident {idx} to SQS: {case['name']}")

        # Lấy payload con bên trong case['payload']
        payload_data = case["payload"]

        # Format message attributes tương đương với headers từ API Gateway
        message_attributes = {
            "TenantId": {"DataType": "String", "StringValue": case["tenant_id"]},
            "CorrelationId": {"DataType": "String", "StringValue": case["correlation_id"]},
        }

        try:
            start_time = time.time()
            response = sqs_client.send_message(
                QueueUrl=buffer_queue_url, MessageBody=json.dumps(payload_data), MessageAttributes=message_attributes
            )
            duration = time.time() - start_time
            print(f"SUCCESS (MessageId: {response.get('MessageId')}, Time: {duration:.2f}s)")
        except Exception as e:
            print(f"ERROR sending SQS: {e}")

        if idx < len(dataset):
            print("Waiting 3 seconds before next incident...")
            time.sleep(3)

    print("\n=================================================================")
    print("COMPLETED SENDING DATASET TO SQS BUFFER!")
    print("WORKER WILL PROCESS IN A FEW SECONDS")
    print("=================================================================")


if __name__ == "__main__":
    run_demo()
# Trigger new build for unique ECR tag verification
