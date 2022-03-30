"use strict";

var AWS = require("aws-sdk");
const dynamo = new AWS.DynamoDB();
const s3 = new AWS.S3({ signatureVersion: "v4" });
const ses = new AWS.SES();

var defaultConfig = {
  emailBucket: "${email_bucket}",
  emailKeyPrefix: "",
  forwardMapping: "${mapping}",
  defaultForwardMapping: "${recipient}",
};

/**
 * Parses the SES event record provided for the `mail` and `receipients` data.
 *
 * @param {object} data - Data bundle with context, email, etc.
 *
 * @return {object} - Promise resolved with data.
 */
exports.parseEvent = function (data) {
  // Validate characteristics of a SES event record.
  if (
    !data.event ||
    !data.event.hasOwnProperty("Records") ||
    data.event.Records.length !== 1 ||
    !data.event.Records[0].hasOwnProperty("eventSource") ||
    data.event.Records[0].eventSource !== "aws:ses" ||
    data.event.Records[0].eventVersion !== "1.0"
  ) {
    data.log({
      message: "parseEvent() received invalid SES message:",
      level: "error",
      event: JSON.stringify(data.event),
    });
    return Promise.reject(new Error("Error: Received invalid SES message."));
  }

  data.email = data.event.Records[0].ses.mail;
  data.recipients = data.event.Records[0].ses.receipt.recipients;
  return Promise.resolve(data);
};

/**
 * Transforms the original recipients to the desired forwarded destinations.
 *
 * @param {object} data - Data bundle with context, email, etc.
 *
 * @return {object} - Promise resolved with data.
 */
exports.transformRecipients = function (data) {
  data.originalRecipients = data.recipients;
  return Promise.all(
    data.recipients.map((original) =>
      dynamo
        .getItem({
          TableName: data.config.forwardMapping,
          Key: { id: { S: original } },
        })
        .promise()
        .then((r) => ({
          forward: r.Item?.forward?.S || data.config.defaultForwardMapping,
          method: r.Item?.method?.S || "email",
        }))
        .catch((err) => {
          data.log({
            level: "error",
            message: "dynamo forward mapping: " + err.message,
            error: err,
            stack: err.stack,
          });
          return {
            forward: data.config.defaultForwardMapping,
            method: "email",
          };
        })
        .then((args) => ({ original, ...args }))
    )
  ).then((newRecipients) => {
    data.recipients = newRecipients;
    return data;
  });
};

/**
 * Fetches the message data from S3.
 *
 * @param {object} data - Data bundle with context, email, etc.
 *
 * @return {object} - Promise resolved with data.
 */
exports.fetchMessage = function (data) {
  // Copying email object to ensure read permission
  data.log({
    level: "info",
    message:
      "Fetching email at s3://" +
      data.config.emailBucket +
      "/" +
      data.config.emailKeyPrefix +
      data.email.messageId,
  });
  return new Promise(function (resolve, reject) {
    s3.copyObject(
      {
        Bucket: data.config.emailBucket,
        CopySource:
          data.config.emailBucket +
          "/" +
          data.config.emailKeyPrefix +
          data.email.messageId,
        Key: data.config.emailKeyPrefix + data.email.messageId,
        ACL: "private",
        ContentType: "text/plain",
        StorageClass: "STANDARD",
      },
      function (err) {
        if (err) {
          data.log({
            level: "error",
            message: "copyObject() returned error:",
            error: err,
            stack: err.stack,
          });
          return reject(
            new Error("Error: Could not make readable copy of email.")
          );
        }

        // Load the raw email from S3
        s3.getObject(
          {
            Bucket: data.config.emailBucket,
            Key: data.config.emailKeyPrefix + data.email.messageId,
          },
          function (err, result) {
            if (err) {
              data.log({
                level: "error",
                message: "getObject() returned error:",
                error: err,
                stack: err.stack,
              });
              return reject(
                new Error("Error: Failed to load message body from S3.")
              );
            }
            data.emailData = result.Body.toString();
            return resolve(data);
          }
        );
      }
    );
  });
};

/**
 * Processes the message data, making updates to recipients and other headers
 * before forwarding message.
 *
 * @param {object} data - Data bundle with context, email, etc.
 *
 * @return {object} - Promise resolved with data.
 */
exports.processMessage = function (data) {
  var match = data.emailData.match(/^((?:.+\r?\n)*)(\r?\n(?:.*\s+)*)/m);
  var header = match && match[1] ? match[1] : data.emailData;
  var body = match && match[2] ? match[2] : "";

  // Add "Reply-To:" with the "From" address if it doesn't already exists
  if (!/^reply-to:[\t ]?/im.test(header)) {
    match = header.match(/^from:[\t ]?(.*(?:\r?\n\s+.*)*\r?\n)/im);
    var from = match && match[1] ? match[1] : "";
    if (from) {
      header = header + "Reply-To: " + from;
      data.log({
        level: "info",
        message: "Added Reply-To address of: " + from,
      });
    } else {
      data.log({
        level: "info",
        message:
          "Reply-To address not added because From address was not " +
          "properly extracted.",
      });
    }
  }

  // SES does not allow sending messages from an unverified address,
  // so replace the message's "From:" header with the original
  // recipient (which is a verified domain)
  header = header.replace(
    /^from:[\t ]?(.*(?:\r?\n\s+.*)*)/gim,
    function (match, from) {
      var fromText;
      var fromEmail = data.event?.Records?.[0]?.ses?.mail?.destination?.[0];
      if (fromEmail) {
        fromText =
          "From: " + from.replace(/<(.*)>/, "").trim() + " <" + fromEmail + ">";
      } else {
        fromText =
          "From: " +
          from.replace("<", "at ").replace(">", "") +
          " <" +
          data.originalRecipient +
          ">";
      }
      return fromText;
    }
  );

  // Add a prefix to the Subject
  if (data.config.subjectPrefix) {
    header = header.replace(
      /^subject:[\t ]?(.*)/gim,
      function (match, subject) {
        return "Subject: " + data.config.subjectPrefix + subject;
      }
    );
  }

  // Replace original 'To' header with a manually defined one
  if (data.config.toEmail) {
    header = header.replace(
      /^to:[\t ]?(.*)/gim,
      () => "To: " + data.config.toEmail
    );
  }

  // Remove the Return-Path header.
  header = header.replace(/^return-path:[\t ]?(.*)\r?\n/gim, "");

  // Remove Sender header.
  header = header.replace(/^sender:[\t ]?(.*)\r?\n/gim, "");

  // Remove Message-ID header.
  header = header.replace(/^message-id:[\t ]?(.*)\r?\n/gim, "");

  // Remove all DKIM-Signature headers to prevent triggering an
  // "InvalidParameterValue: Duplicate header 'DKIM-Signature'" error.
  // These signatures will likely be invalid anyways, since the From
  // header was modified.
  header = header.replace(/^dkim-signature:[\t ]?.*\r?\n(\s+.*\r?\n)*/gim, "");

  data.emailData = header + body;
  return Promise.resolve(data);
};

/**
 * Send email using the SES sendRawEmail command.
 *
 * @param {object} data - Data bundle with context, email, etc.
 *
 * @return {object} - Promise resolved with data.
 */
exports.sendMessage = function (data) {
  return Promise.all(
    data.recipients.map((r) => {
      if (r.method === "email") {
        const params = {
          Destinations: [r.forward],
          Source: r.original,
          RawMessage: {
            Data: data.emailData,
          },
        };
        data.log({
          level: "info",
          message:
            "sendMessage: Sending email via SES. Original recipients: " +
            r.original +
            ". Transformed recipients: " +
            Destinations.join(", ") +
            ".",
        });
        return new Promise(function (resolve, reject) {
          ses.sendRawEmail(params, function (err, result) {
            if (err) {
              data.log({
                level: "error",
                message: "sendRawEmail() returned error.",
                error: err,
                stack: err.stack,
              });
              return reject(new Error("Error: Email sending failed."));
            }
            data.log({
              level: "info",
              message: "sendRawEmail() successful.",
              result: result,
            });
            resolve(result);
          });
        });
      } else if (r.method === 's3') {
        return s3.upload({
          Bucket: r.forward,
          Key: "_emails/" + r.original + "/",
          Body: r.emailData,
        }).promise();
      } else {
        data.log({
          level: "info",
          message: "Unknown method " + r.method,
        });
        return;
      }
    })
  ).then(() => data);
};

/**
 * Handler function to be invoked by AWS Lambda with an inbound SES email as
 * the event.
 *
 * @param {object} event - Lambda event from inbound email received by AWS SES.
 * @param {object} context - Lambda context object.
 * @param {object} callback - Lambda callback object.
 * @param {object} overrides - Overrides for the default data, including the
 * configuration, SES object, and S3 object.
 */
exports.handler = function (event, context, callback, overrides) {
  var steps =
    overrides && overrides.steps
      ? overrides.steps
      : [
          exports.parseEvent,
          exports.transformRecipients,
          exports.fetchMessage,
          exports.processMessage,
          exports.sendMessage,
        ];
  var data = {
    event: event,
    callback: callback,
    context: context,
    config: overrides && overrides.config ? overrides.config : defaultConfig,
    log: overrides && overrides.log ? overrides.log : console.log,
  };
  Promise.series(steps, data)
    .then(function (data) {
      data.log({
        level: "info",
        message: "Process finished successfully.",
      });
      return data.callback();
    })
    .catch(function (err) {
      data.log({
        level: "error",
        message: "Step returned error: " + err.message,
        error: err,
        stack: err.stack,
      });
      return data.callback(new Error("Error: Step returned error."));
    });
};

Promise.series = function (promises, initValue) {
  return promises.reduce(function (chain, promise) {
    if (typeof promise !== "function") {
      return Promise.reject(
        new Error("Error: Invalid promise item: " + promise)
      );
    }
    return chain.then(promise);
  }, Promise.resolve(initValue));
};
