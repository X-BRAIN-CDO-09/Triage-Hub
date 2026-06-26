exports.handler = async (event) => {
  console.log("Notify Dispatcher Event:", JSON.stringify(event));
  return { statusCode: 200, body: JSON.stringify({ status: "success" }) };
};
