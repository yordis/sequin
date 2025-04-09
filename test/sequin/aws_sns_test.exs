defmodule Sequin.Aws.SNSTest do
  use Sequin.Case, async: true

  alias Sequin.Aws.HttpClient
  alias Sequin.Aws.SNS
  alias Sequin.Factory.SinkFactory

  @topic_arn "arn:aws:sns:us-east-1:123456789012:test-topic"

  setup do
    client =
      "test"
      |> AWS.Client.create("test", "us-east-1")
      |> HttpClient.put_client()

    {:ok, client: client}
  end

  describe "publish_messages/3" do
    test "successfully publishes batch of messages", %{client: client} do
      messages = [
        SinkFactory.sns_message(),
        SinkFactory.sns_message()
      ]

      Req.Test.stub(Sequin.Aws.HttpClient, fn conn ->
        assert conn.host == "sns.us-east-1.amazonaws.com"
        assert conn.method == "POST"

        Req.Test.json(conn, %{
          "PublishBatchResponse" => %{
            "PublishBatchResult" => %{
              "Failed" => :none,
              "Successful" => %{
                "member" => %{
                  "Id" => "23df4256-b838-4538-ad38-b4231aa2b71c",
                  "MessageId" => "73260025-473a-5494-b7d2-6055e8dd4bfd",
                  "SequenceNumber" => "10000000000000003000"
                }
              }
            },
            "ResponseMetadata" => %{
              "RequestId" => "abbf754a-da6a-557c-865b-153a6b69bc16"
            }
          }
        })
      end)

      assert :ok = SNS.publish_messages(client, @topic_arn, messages)
    end

    test "returns error when batch publish fails", %{client: client} do
      messages = [SinkFactory.sns_message()]

      Req.Test.stub(Sequin.Aws.HttpClient, fn conn ->
        Req.Test.json(conn, %{
          "Failed" => [
            %{
              "Id" => "1",
              "Code" => "InternalError",
              "Message" => "Internal Error occurred"
            }
          ],
          "Successful" => []
        })
      end)

      assert {:error, %{"Failed" => [_failed_message]}, _} = SNS.publish_messages(client, @topic_arn, messages)
    end
  end

  describe "topic_meta/2" do
    test "successfully retrieves topic metadata", %{client: client} do
      Req.Test.stub(Sequin.Aws.HttpClient, fn conn ->
        assert conn.method == "POST"
        assert String.contains?(conn.host, "sns.us-east-1.amazonaws.com")

        Req.Test.json(conn, %{
          "GetTopicAttributesResponse" => %{
            "GetTopicAttributesResult" => %{
              "Attributes" => %{
                "entry" => [
                  %{
                    "key" => "TopicArn",
                    "value" => "arn:aws:sns:us-east-2:689238261712:testing.fifo"
                  },
                  %{"key" => "FifoTopic", "value" => "true"},
                  %{"key" => "DisplayName", "value" => :none},
                  %{"key" => "ContentBasedDeduplication", "value" => "false"},
                  %{"key" => "FifoThroughputScope", "value" => "MessageGroup"},
                  %{"key" => "SubscriptionsConfirmed", "value" => "0"}
                ]
              }
            },
            "ResponseMetadata" => %{
              "RequestId" => "abbf754a-da6a-557c-865b-153a6b69bc16"
            }
          }
        })
      end)

      assert :ok = SNS.topic_meta(client, @topic_arn)
    end
  end
end
