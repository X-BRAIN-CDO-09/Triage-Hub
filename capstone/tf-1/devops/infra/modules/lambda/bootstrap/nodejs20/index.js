exports.handler = async () => ({
  statusCode: 503,
  body: JSON.stringify({
    message: "Lambda code has not been deployed by App CI/CD yet."
  })
});
