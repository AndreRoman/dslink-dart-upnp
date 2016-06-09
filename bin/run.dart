import "dart:convert";

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

main(List<String> args) async {
  var func = () async {
    await _main(args);
  };

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

  var discovery = new DeviceDiscoverer();

  autoDestroyDeviceChecker = Scheduler.safeEvery(Interval.FIVE_SECONDS, () async {
    for (SimpleNode node in link.getNode("/").children.values.toList()) {
      String pingUrl = node.attributes["@pingUrl"];

      if (pingUrl != null) {
        var resp = await UpnpCommon.httpClient.get(pingUrl)
          .timeout(const Duration(seconds: 5), onTimeout: () {
          return null;
        });

        if (resp == null || resp.statusCode != 200) {
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
    searchInterval: const Duration(hours: 1)
  )) {
    await setupClient(client);
  }
}

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

setupClient(DiscoveredClient client) async {
  try {
    var device = await client.getDevice();
    var nodePath = "/${NodeNamer.createName(device.uuid)}";

    setOrUpdateNode(nodePath, {
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
      "services": {
        r"$name": "Services"
      }
    });

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
        }
      });
      var service = await desc.getService();

      if (service == null) {
        continue;
      }

      var actionNodeMap = {};

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

            var result = await act.invoke(args);

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

        actionNodeMap[act.name] = actionNode;
      }

      setOrUpdateNode(servicePath, actionNodeMap);
    }
  } catch (e, stack) {
    logger.fine("Failed to fetch device: ${client.location}", e, stack);
  }
}

