const { DynamoDBClient, GetItemCommand } = require("@aws-sdk/client-dynamodb");
const { SQSClient, SendMessageCommand } = require("@aws-sdk/client-sqs");

const dynamoClient = new DynamoDBClient({});
const sqsClient = new SQSClient({});

const QUEUE_URL = process.env.SQS_QUEUE_URL;
const DYNAMODB_TABLE = process.env.DYNAMODB_TABLE;
const DEFAULT_ENVIRONMENT =
	process.env.DEFAULT_ENVIRONMENT || process.env.ENVIRONMENT || "sandbox";
const TENANT_CONFIG_SK = process.env.TENANT_CONFIG_SK || "CONFIG";
const TENANT_CONFIG_PK_PREFIX =
	process.env.TENANT_CONFIG_PK_PREFIX || "TENANT#";
const PROCESS_RESOLVED_ALERTS =
	(process.env.PROCESS_RESOLVED_ALERTS || "false").toLowerCase() === "true";

const VALID_ENVIRONMENTS = new Set(["prod", "staging", "sandbox"]);
const VALID_SEVERITIES = new Set([
	"critical",
	"high",
	"medium",
	"low",
	"unknown",
]);

exports.handler = async (event) => {
	if (isSqsEvent(event)) {
		const results = [];
		for (const record of event.Records) {
			results.push(await handleApiGatewayLikeEvent(buildEventFromSqsRecord(record)));
		}
		return jsonResponse(202, {
			status: "Processed",
			records: results.length,
		});
	}

	return handleApiGatewayLikeEvent(event);
};

async function handleApiGatewayLikeEvent(event) {
	console.log(
		"Received alert ingestion request:",
		JSON.stringify({
			requestContext: event.requestContext,
			headers: redactHeaders(event.headers || {}),
			isBase64Encoded: event.isBase64Encoded,
			hasBody: Boolean(event.body),
		}),
	);

	if (!QUEUE_URL || !DYNAMODB_TABLE) {
		console.error("Lambda is missing required environment variables", {
			hasQueueUrl: Boolean(QUEUE_URL),
			hasDynamoTable: Boolean(DYNAMODB_TABLE),
		});
		return jsonResponse(500, { error: "Lambda configuration error" });
	}

	if (!event.body) {
		return jsonResponse(400, { error: "Missing request body" });
	}

	let payload;
	try {
		payload = parseBody(event);
	} catch (err) {
		console.warn("Invalid JSON body", { error: err.message });
		return jsonResponse(400, { error: "Invalid JSON body" });
	}

	const alerts = extractAlerts(payload);
	if (alerts.length === 0) {
		console.warn("Webhook body contained no alerts");
		return jsonResponse(202, {
			status: "Processed",
			accepted: 0,
			dropped: 0,
			reason: "no_alerts",
		});
	}

	const tenantCache = new Map();
	const accepted = [];
	const dropped = [];

	for (const alert of alerts) {
		const context = buildAlertContext(payload, alert, event.headers || {});
		const alertStatus = String(
			context.alert.status || context.payload.status || "",
		).toLowerCase();

		if (!PROCESS_RESOLVED_ALERTS && alertStatus === "resolved") {
			dropped.push(dropRecord(context, "resolved_alert"));
			continue;
		}

		const tenantId = extractTenantId(context);

		if (!tenantId) {
			dropped.push(dropRecord(context, "missing_tenant_id"));
			continue;
		}

		if (context.headerTenantId && context.headerTenantId !== tenantId) {
			dropped.push(
				dropRecord(context, "tenant_header_label_mismatch", {
					tenant_id: tenantId,
				}),
			);
			continue;
		}

		const tenant = await getTenantConfig(tenantId, tenantCache);
		if (!tenant.exists) {
			dropped.push(
				dropRecord(context, "invalid_tenant", { tenant_id: tenantId }),
			);
			continue;
		}
		if (!tenant.active) {
			dropped.push(
				dropRecord(context, "inactive_tenant", { tenant_id: tenantId }),
			);
			continue;
		}

		const seed = buildIncidentSeed(context, tenantId, tenant.item);
		await sendSeedToSqs(seed);
		accepted.push({
			tenant_id: tenantId,
			incident_id: seed.incident_id,
			alertname: seed.labels.alertname,
			service: seed.service,
		});
	}

	console.log("Alert ingestion completed", {
		accepted: accepted.length,
		dropped: dropped.length,
		accepted_alerts: accepted,
		dropped_alerts: dropped,
	});

	return jsonResponse(202, {
		status: "Processed",
		accepted: accepted.length,
		dropped: dropped.length,
		accepted_alerts: accepted,
		dropped_alerts: dropped,
	});
}

function isSqsEvent(event) {
	return (
		Array.isArray(event?.Records) &&
		event.Records.some((record) => record.eventSource === "aws:sqs")
	);
}

function buildEventFromSqsRecord(record) {
	const headers = {};
	const tenantId = sqsMessageAttributeValue(record, "TenantId");
	const correlationId = sqsMessageAttributeValue(record, "CorrelationId");
	const source = sqsMessageAttributeValue(record, "Source");

	if (tenantId) headers["x-tenant-id"] = tenantId;
	if (correlationId) headers["x-correlation-id"] = correlationId;
	if (source) headers["x-source"] = source;

	return {
		body: record.body,
		headers,
		isBase64Encoded: false,
		requestContext: {
			source: "sqs",
			messageId: record.messageId,
		},
	};
}

function sqsMessageAttributeValue(record, name) {
	return record.messageAttributes?.[name]?.stringValue;
}

function parseBody(event) {
	const text = event.isBase64Encoded
		? Buffer.from(event.body, "base64").toString("utf8")
		: event.body;
	return JSON.parse(text);
}

function extractAlerts(payload) {
	if (Array.isArray(payload.alerts)) return payload.alerts;
	if (payload.alert && typeof payload.alert === "object")
		return [payload.alert];
	if (
		payload.labels ||
		payload.annotations ||
		payload.alertname ||
		payload.tenant_id
	)
		return [payload];
	return [];
}

function buildAlertContext(payload, alert, headers) {
	const normalizedHeaders = normalizeHeaders(headers);
	return {
		payload,
		alert,
		headers: normalizedHeaders,
		headerTenantId: normalizedHeaders["x-tenant-id"],
		commonLabels: payload.commonLabels || {},
		groupLabels: payload.groupLabels || {},
		labels: alert.labels || payload.labels || {},
		annotations: alert.annotations || payload.annotations || {},
	};
}

function normalizeHeaders(headers) {
	return Object.fromEntries(
		Object.entries(headers || {}).map(([key, value]) => [
			key.toLowerCase(),
			String(value),
		]),
	);
}

function extractTenantId(context) {
	return firstNonEmpty([
		context.alert.tenant_id,
		context.labels.tenant_id,
		context.commonLabels.tenant_id,
		context.groupLabels.tenant_id,
		context.headerTenantId,
	]);
}

// Validates tenant against DynamoDB here
async function getTenantConfig(tenantId, cache) {
	if (cache.has(tenantId)) return cache.get(tenantId);

	const result = await dynamoClient.send(
		new GetItemCommand({
			TableName: DYNAMODB_TABLE,
			Key: {
				PK: { S: `${TENANT_CONFIG_PK_PREFIX}${tenantId}` },
				SK: { S: TENANT_CONFIG_SK },
			},
		}),
	);

	const item = result.Item || null;
	const status = item?.status?.S || item?.tenant_status?.S || "active";
	const tenant = {
		exists: Boolean(item),
		active: Boolean(item) && status.toLowerCase() === "active",
		item,
	};
	cache.set(tenantId, tenant);
	return tenant;
}

// Converts a raw Alertmanager alert into the lightweight message format
function buildIncidentSeed(context, tenantId, tenantItem) {
	const now = new Date().toISOString();
	const alertname = firstNonEmpty([
		context.labels.alertname,
		context.commonLabels.alertname,
		context.alert.alertname,
		"unknown-alert",
	]);
	const fingerprint = firstNonEmpty([
		context.alert.fingerprint,
		context.labels.fingerprint,
		context.alert.id,
		stableHash(
			JSON.stringify({
				tenant_id: tenantId,
				alertname,
				labels: context.labels,
				startsAt: context.alert.startsAt,
			}),
		),
	]);

	const environment = normalizeEnvironment(
		firstNonEmpty([
			context.labels.environment,
			context.labels.env,
			context.commonLabels.environment,
			context.commonLabels.env,
			ddbString(tenantItem, "environment"),
			DEFAULT_ENVIRONMENT,
		]),
	);

	const service = normalizeService(
		firstNonEmpty([
			context.labels.service,
			context.labels.deployment,
			context.labels.pod,
			context.labels.container,
			context.labels.job,
			context.labels.namespace,
			ddbString(tenantItem, "default_service"),
			"unknown",
		]),
	);

	const labels = {
		...context.commonLabels,
		...context.groupLabels,
		...context.labels,
		source: "prometheus-alertmanager",
		alertmanager_status:
			context.payload.status || context.alert.status || "unknown",
		receiver: context.payload.receiver,
		group_key: context.payload.groupKey,
		fingerprint,
	};

	return {
		schema_version: "tf1.incident_seed.v1",
		tenant_id: tenantId,
		correlation_id: `corr-${safeId(tenantId)}-${safeId(alertname)}-${safeId(fingerprint)}`,
		incident_id: `inc-${safeId(tenantId)}-${safeId(alertname)}-${safeId(fingerprint)}`,
		environment,
		service,
		severity: normalizeSeverity(
			firstNonEmpty([
				context.labels.severity,
				context.commonLabels.severity,
				context.alert.severity,
				"unknown",
			]),
		),
		title: firstNonEmpty([
			context.annotations.summary,
			context.alert.title,
			humanizeAlertName(alertname),
		]),
		description: firstNonEmpty([
			context.annotations.description,
			context.alert.description,
			`Prometheus alert ${alertname} is ${context.alert.status || context.payload.status || "active"}.`,
		]),
		started_at: normalizeTimestamp(
			context.alert.startsAt || context.alert.started_at || now,
		),
		received_at: now,
		labels,
	};
}

async function sendSeedToSqs(seed) {
	const messageBody = JSON.stringify(seed);
	console.log("Formatted incident seed message body for SQS:", messageBody);

	const command = new SendMessageCommand({
		QueueUrl: QUEUE_URL,
		MessageBody: messageBody,
		MessageAttributes: {
			TenantId: { DataType: "String", StringValue: seed.tenant_id },
			IncidentId: { DataType: "String", StringValue: seed.incident_id },
			AlertName: {
				DataType: "String",
				StringValue: seed.labels.alertname || "unknown-alert",
			},
			Severity: { DataType: "String", StringValue: seed.severity },
		},
	});
	const result = await sqsClient.send(command);
	console.log("Successfully pushed incident seed to SQS", {
		message_id: result.MessageId,
		tenant_id: seed.tenant_id,
		incident_id: seed.incident_id,
		alertname: seed.labels.alertname,
	});
}

function normalizeSeverity(value) {
	const severity = String(value || "unknown").toLowerCase();
	const mapped =
		{
			warn: "medium",
			warning: "medium",
			info: "low",
			informational: "low",
			error: "high",
			page: "high",
			sev1: "critical",
			p1: "critical",
			sev2: "high",
			p2: "high",
			sev3: "medium",
			p3: "medium",
		}[severity] || severity;
	return VALID_SEVERITIES.has(mapped) ? mapped : "unknown";
}

function ddbString(item, key) {
	if (!item || !item[key]) return undefined;
	if (item[key].S !== undefined) return item[key].S;
	if (item[key].N !== undefined) return item[key].N;
	if (item[key].BOOL !== undefined) return String(item[key].BOOL);
	return undefined;
}

function normalizeEnvironment(value) {
	const environment = String(value || DEFAULT_ENVIRONMENT).toLowerCase();
	return VALID_ENVIRONMENTS.has(environment)
		? environment
		: DEFAULT_ENVIRONMENT;
}

function normalizeService(value) {
	return String(value || "unknown").trim() || "unknown";
}

function normalizeTimestamp(value) {
	const date = new Date(value);
	if (Number.isNaN(date.getTime())) return new Date().toISOString();
	return date.toISOString();
}

function firstNonEmpty(values) {
	for (const value of values) {
		if (value === undefined || value === null) continue;
		const stringValue = String(value).trim();
		if (stringValue) return stringValue;
	}
	return undefined;
}

function safeId(value) {
	return (
		String(value || "unknown")
			.toLowerCase()
			.replace(/[^a-z0-9]+/g, "-")
			.replace(/^-+|-+$/g, "")
			.slice(0, 80) || "unknown"
	);
}

function humanizeAlertName(alertname) {
	return String(alertname || "Unknown alert")
		.replace(/([a-z])([A-Z])/g, "$1 $2")
		.replace(/[_-]+/g, " ");
}

function stableHash(value) {
	let hash = 5381;
	for (let i = 0; i < value.length; i += 1) {
		hash = (hash << 5) + hash + value.charCodeAt(i);
		hash |= 0;
	}
	return Math.abs(hash).toString(36);
}

function dropRecord(context, reason, extra = {}) {
	const record = {
		reason,
		alertname:
			context.labels.alertname ||
			context.commonLabels.alertname ||
			context.alert.alertname ||
			"unknown-alert",
		status: context.alert.status || context.payload.status || "unknown",
		...extra,
	};
	console.warn("Dropping alert", record);
	return record;
}

function redactHeaders(headers) {
	const redacted = {};
	for (const [key, value] of Object.entries(headers || {})) {
		redacted[key] =
			key.toLowerCase() === "x-api-key" ? "***redacted***" : value;
	}
	return redacted;
}

function jsonResponse(statusCode, body) {
	return {
		statusCode,
		headers: { "Content-Type": "application/json" },
		body: JSON.stringify(body),
	};
}
