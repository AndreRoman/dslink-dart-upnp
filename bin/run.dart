import "dart:async";
import "dart:convert";

import "package:http/http.dart" as http;

import "package:dslink/dslink.dart";
import "package:dslink/nodes.dart";
import "package:dslink/utils.dart";

import "package:logging/logging.dart";

import "package:upnp/upnp.dart";
import "package:upnp/src/utils.dart";
import "package:xml/xml.dart";
import "package:stack_trace/stack_trace.dart";

LinkProvider link;
SimpleNodeProvider provider;
Disposable autoDestroyDeviceChecker;

StateSubscriptionManager subscriptionManager;

main(List<String> args) async {
  var func = () async {
    await _main(args);
  };

  subscriptionManager = new StateSubscriptionManager();
  await subscriptionManager.init();

  if (const bool.fromEnvironment("upnp.debug", defaultValue: false)) {
    await Chain.capture(() async {
      await func();
    });
  } else {
    await func();
  }
}

_main(List<String> args) async {
  link = new LinkProvider(args, "UPNP-");
  link.init();
  link.connect();
  provider = link.provider;

  SimpleNode subscriptionClientPortNode = link.addNode("/subscriptionClientPort", {
    r"$name": "Subscription Client Port",
    r"$type": "number",
    "?value": subscriptionManager.server.port
  });
  subscriptionClientPortNode.serializable = false;

  var discovery = new DeviceDiscoverer();

  autoDestroyDeviceChecker = Scheduler.safeEvery(Interval.FIVE_SECONDS, () async {
    for (SimpleNode node in link.getNode("/").children.values.toList()) {
      String pingUrl = node.attributes["@pingUrl"];

      if (pingUrl != null) {
        http.Response resp;
        try {
          resp = await UpnpCommon.httpClient.get(pingUrl)
            .timeout(const Duration(seconds: 10), onTimeout: () {
            return null;
          });
        } catch (e) {}
        if (resp == null || resp.statusCode != 200) {
          SimpleNode uuidNode = node.getChild("uuid");
          if (uuidNode != null) {
            var val = uuidNode.value;
            for (String key in _valueUpdateSubs.keys.toList()) {
              if (key.startsWith("${val}:")) {
                var sub = _valueUpdateSubs.remove(key);
                if (sub != null) {
                  sub.cancel();
                }
              }
            }
          }
          _currentDeviceIds.remove(node.getConfig(r"$discoverId"));
          link.removeNode(node.path);
        }
      }
    }
  });

  var discoverDevicesNode = new SimpleActionNode("/discover", (Map<String, dynamic> args) {
    discovery.search();
  });

  discoverDevicesNode.configs.addAll({
    r"$name": "Discover Devices",
    r"$invokable": "write"
  });

  provider.setNode(discoverDevicesNode.path, discoverDevicesNode);

  await for (DiscoveredClient client in discovery.quickDiscoverClients(
    searchInterval: const Duration(seconds: 30)
  )) {
    var uuid = client.usn.split("::").first;
    if (_currentDeviceIds.contains(uuid)) {
      continue;
    }

    if (shouldCheckDevice(uuid)) {
      setupClient(client, uuid);
    }
  }
}

Set<String> _currentDeviceIds = new Set<String>();

class DirectMessageException {
  final String message;

  DirectMessageException(this.message);

  @override
  String toString() => message;
}

SimpleNode setOrUpdateNode(String path, Map<String, dynamic> map) {
  SimpleNode node = link[path];

  if (node == null) {
    node = link.addNode(path, map);

    for (String key in map.keys) {
      var value = map[key];

      if (value is SimpleNode) {
        node.addChild(key, value);
        node.provider.setNode(value.path, value);
      }
    }
  } else {
    for (String key in map.keys) {
      var value = map[key];
      if (key.startsWith("@")) {
        var oldValue = node.attributes[key];

        if (oldValue != value) {
          node.attributes[key] = value;
        }
      } else if (key.startsWith(r"$")) {
        var oldValue = node.configs[key];

        if (value != oldValue) {
          node.configs[key] = value;
        }
      } else {
        if (value is SimpleNode) {
          node.addChild(key, value);
          node.provider.setNode(value.path, value);
        } else {
          SimpleNode childNode = node.children[key];

          if (childNode != null) {
            setOrUpdateNode("${path}/${key}", value);
          } else {
            link.addNode("${node.path}/${key}", value);
          }
        }
      }
    }
  }

  return node;
}

Map<String, int> _cooldown = {};

setupClient(DiscoveredClient client, String uuid) async {
  await runZoned(() async {
    await doSetupClient(client, uuid);
  }, onError: (e, stack) {
    logger.fine(
      "Failed to setup device at ${client.location} (${client.usn})",
      e,
      stack
    );
  });
}

doSetupClient(DiscoveredClient client, String uuid) async {
  try {
    var device = await client.getDevice();
    _currentDeviceIds.add(uuid);
    var nodePath = "/${NodeNamer.createName(device.uuid)}";

    var ourIpToDevice = await InternalNetworkUtils.getMostLikelyHost(
      Uri.parse(device.url)
    );

    var deviceNodeMap = {
      r"$discoverId": uuid,
      r"$name": device.friendlyName,
      "@pingUrl": client.location,
      "friendlyName": {
        r"$name": "Friendly Name",
        r"$type": "string",
        "?value": device.friendlyName
      },
      "manufacturer": {
        r"$name": "Manufacturer",
        r"$type": "string",
        "?value": device.manufacturer
      },
      "modelName": {
        r"$name": "Model Name",
        r"$type": "string",
        "?value": device.modelName
      },
      "modelNumber": {
        r"$name": "Model Number",
        r"$type": "string",
        "?value": device.modelNumber
      },
      "deviceType": {
        r"$name": "Device Type",
        r"$type": "string",
        "?value": device.deviceType
      },
      "uuid": {
        r"$name": "UUID",
        r"$type": "string",
        "?value": device.uuid
      },
      "udn": {
        r"$name": "UDN",
        r"$type": "string",
        "?value": device.udn
      },
      "url": {
        r"$name": "Url",
        r"$type": "string",
        "?value": device.url
      },
      "presentationUrl": {
        r"$name": "Presentation Url",
        r"$type": "string",
        "?value": device.presentationUrl
      },
      "backReferenceAddress": {
        r"$name": "Client Reference IP",
        r"$type": "string",
        "?value": ourIpToDevice
      },
      "services": {
        r"$name": "Services"
      }
    };

    setOrUpdateNode(nodePath, deviceNodeMap);

    var sendDeviceRequestNode = new SendDeviceRequest(
      device,
      "${nodePath}/sendDeviceRequest"
    );
    provider.setNode(sendDeviceRequestNode.path, sendDeviceRequestNode);

    for (ServiceDescription desc in device.services) {
      var serviceIdName = NodeNamer.createName(desc.id);
      var servicePath = "${nodePath}/services/${serviceIdName}";
      SimpleNode serviceNode = setOrUpdateNode(servicePath, {
        r"$name": desc.id,
        "id": {
          r"$name": "ID",
          r"$type": "string",
          "?value": desc.id
        },
        "type": {
          r"$name": "Type",
          r"$type": "string",
          "?value": desc.type
        },
        "controlUrl": {
          r"$name": "Control Url",
          r"$type": "string",
          "?value": desc.controlUrl
        },
        "eventSubUrl": {
          r"$name": "Event Url",
          r"$type": "string",
          "?value": desc.eventSubUrl
        },
        "scpdUrl": {
          r"$name": "SCPD Url",
          r"$type": "string",
          "?value": desc.scpdUrl
        },
        "variables": {
          r"$name": "Variables"
        }
      });
      var service = await desc.getService();

      if (service == null) {
        continue;
      }

      var serviceProviderMap = {};
      var variableNodeMap = {};

      for (Action act in service.actions) {
        if (act.name == null) {
          continue;
        }

        var actionPathName = NodeNamer.createName(act.name);
        var actionPath = "${serviceNode.path}/${actionPathName}";
        var actionResultNames = act.arguments.where((x) => x.isRetVal).map((x) {
          return x.name;
        }).toList();

        var isResultJson = false;

        var actionParamDefs = [];

        for (ActionArgument a in act.arguments
          .where((x) => !x.isRetVal)) {
          actionParamDefs.add({
            r"name": a.name,
            r"type": "dynamic"
          });
        }

        var actionResultDefs = actionResultNames.map((x) {
          return {
            "name": x,
            "type": "dynamic"
          };
        }).toList();

        if (actionResultDefs.isEmpty) {
          actionResultDefs.add({
            "name": "Result",
            "type": "string"
          });
          isResultJson = true;
        }

        var onInvoke = (Map<String, dynamic> args) async {
          try {
            if (logger.isLoggable(Level.FINE)) {
              logger.fine("Invoke ${act.name} with ${args}");
            }

            var result = await act.invoke(args).timeout(
              const Duration(seconds: 5)
            );

            if (logger.isLoggable(Level.FINE)) {
              logger.fine("Got Invoke Result: ${result}");
            }

            var out = [];

            if (isResultJson) {
              out.add([JSON.encode(result)]);
            } else {
              var list = [];
              for (String key in actionResultNames) {
                list.add(result[key].toString());
              }
              out.add(list);
            }

            return out;
          } catch (e, stack) {
            if (logger.isLoggable(Level.FINE)) {
              logger.fine("Got Invoke Error: ${e}");
            }

            if (e is UpnpException) {
              XmlElement el = e.element;
              var errorCode = el.findAllElements("errorCode");
              var errorDesc = el.findAllElements("errorDescription");

              int errorCodeValue = -1;
              String errorDescValue = "Unknown Error: ";

              if (errorCode.isNotEmpty) {
                errorCodeValue = int.parse(errorCode.first.text);
              }

              if (errorDesc.isNotEmpty) {
                errorDescValue = errorDesc.first.text;
              }

              throw new DirectMessageException(
                "${errorDescValue} (Code: ${errorCodeValue})"
              );
            }

            logger.finer("Failed to invoke ${act.name}", e, stack);
            rethrow;
          }
        };

        var actionNode = new SimpleActionNode(actionPath, onInvoke);

        actionNode.configs.addAll({
          r"$name": act.name,
          r"$invokable": "write",
          r"$columns": actionResultDefs,
          r"$params": actionParamDefs
        });

        serviceProviderMap[act.name] = actionNode;
      }

      for (StateVariable v in service.stateVariables) {
        if (v.doesSendEvents != true) {
          continue;
        }

        var name = NodeNamer.createName(v.name);
        variableNodeMap[name] = {
          r"$name": v.name,
          r"$type": "dynamic"
        };
      }

      var tid = "${device.uuid}:${service.type}";
      if (_valueUpdateSubs.containsKey(tid)) {
        var rsub = _valueUpdateSubs.remove(tid);
        if (rsub != null) {
          rsub.cancel();
        }
      }

      var sub = subscriptionManager.subscribeToService(service).listen((Map<String, dynamic> data) {
        for (var key in data.keys) {
          var name = NodeNamer.createName(key);
          var node = link["${servicePath}/variables/${name}"];
          if (node != null) {
            node.updateValue(data[key]);
          }
        }
      }, onError: (e) {});

      _valueUpdateSubs[tid] = sub;

      serviceProviderMap["variables"] = variableNodeMap;
      setOrUpdateNode(servicePath, serviceProviderMap);
    }
  } catch (e, stack) {
    increaseDeviceFail(uuid);
    if (logger.isLoggable(Level.FINEST)) {
      logger.finest("Failed to fetch device: ${client.location}", e, stack);
    } else {
      logger.fine("Failed to fetch device: ${client.location}", e);
    }
  }
}

increaseDeviceFail(String id) {
  int fail = _cooldown[id];
  if (fail == null) {
    fail = 1;
  } else {
    fail++;
  }

  if (fail >= 5) {
    var level = 8;
    logger.fine("Starting cooldown for device ${id} at level ${level}.");
    fail = -level;
  } else {
    logger.fine("Increasing failure count for device ${id} to ${fail}.");
  }

  _cooldown[id] = fail;
}

bool shouldCheckDevice(String id) {
  int c = _cooldown[id];

  if (c != null) {
    if (c.isNegative) {
      c++;
      logger.fine("Cooldown for device ${id} is now at level ${c.abs()}.");
    } else {
      return true;
    }

    if (c == 0) {
      logger.fine("Cooldown for device ${id} is now over.");
      _cooldown.remove(id);
      return true;
    } else {
      _cooldown[id] = c;
      return false;
    }
   }

  return true;
}

Map<String, StreamSubscription> _valueUpdateSubs = {};

class SendDeviceRequest extends SimpleNode {
  Device device;

  SendDeviceRequest(this.device, String path) : super(path) {
    configs[r"$name"] = "Send Device Request";
    configs[r"$invokable"] = "write";
    configs[r"$result"] = "values";
    configs[r"$params"] = [
      {
        "name": "httpPath",
        "type": "string",
        "default": "/"
      },
      {
        "name": "body",
        "type": "string",
        "default": "/"
      },
      {
        "name": "method",
        "type": "enum[GET,DELETE,POST,PUT]",
        "default": "GET"
      },
      {
        "name": "headers",
        "type": "string",
        "default": "{}"
      }
    ];

    configs[r"$columns"] = [
      {
        "name": "statusCode",
        "type": "number"
      },
      {
        "name": "responseBody",
        "type": "string"
      },
      {
        "name": "responseHeaders",
        "type": "string"
      }
    ];
  }

  @override
  onInvoke(Map<String, dynamic> params) async {
    String httpPath = params["httpPath"];
    String body = params["body"];
    String method = params["method"];
    String headers = params["headers"];

    if (httpPath == null) {
      httpPath = "/";
    }

    if (method == null) {
      method = "GET";
    }

    if (body == null || body.toString().isEmpty) {
      body = null;
    }

    if (headers == null || headers.toString().isEmpty) {
      headers = "{}";
    }

    var req = new http.Request(
      method,
      Uri.parse(device.urlBase).resolve(httpPath)
    );

    if (body != null) {
      req.body = body.toString();
    }

    req.headers.addAll(JSON.decode(headers));

    var resp = await UpnpCommon
      .httpClient
      .send(req)
      .timeout(const Duration(seconds: 10));

    var respString = await resp.stream.bytesToString();

    return [
      [
        resp.statusCode,
        respString,
        JSON.encode(resp.headers)
      ]
    ];
  }
}
