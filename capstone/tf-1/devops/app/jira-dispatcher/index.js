exports.handler = async (event) => {
  console.log("Jira Dispatcher Event:", JSON.stringify(event));
  return { statusCode: 200, body: JSON.stringify({ status: "success" }) };
};
