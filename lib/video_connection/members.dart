import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'dart:convert';
import 'package:sdp_transform/sdp_transform.dart';
import 'package:archive/archive.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_browser_client.dart';

class InitializeMemberWebRTC {
  RTCPeerConnection _peerConnection;
  final RTCVideoRenderer _localRenderer;
  final RTCVideoRenderer _remoteRenderer;
  final String roomCode;
  List<String> candidates = [];
  String singleCandidate;
  String rtcString;
  String sdpString;
  MediaStream localStream;
  MqttBrowserClient client;
  String username = "ngtyutmq";
  String passcode = "LuwKDV6Raabe";
  String mqttClientIdentifer = "meetup";
  InitializeMemberWebRTC(
      this._localRenderer, this._remoteRenderer, this.roomCode);

  initRenderers() async {
    await _localRenderer.initialize();
    await _remoteRenderer.initialize();
    _peerConnection = await _createPeerConnection();
    return 0;
  }

  String generateRandomClientID() {
    DateTime now = new DateTime.now();
    return "public_cloud" + now.toString();
  }

  Future<bool> initializeMQTTClient() async {
    this.client = new MqttBrowserClient(
        "wss://hairdresser.cloudmqtt.com", generateRandomClientID());
    this.client.logging(on: false);
    this.client.port = 36642;
    this.client.keepAlivePeriod = 1600;
    this.client.onDisconnected = onDisconnected;
    this.client.onConnected = onConnected;
    this.client.onSubscribed = onSubscribed;
    // this.client.autoReconnect = true;
    // this.client..websocketProtocols = ["websockets"];
    final connMess = MqttConnectMessage()
        .keepAliveFor(1600)
        // .startClean() // Non persistent session for testing
        .withWillQos(MqttQos.atLeastOnce);
    // .withClientIdentifier(this.mqttClientIdentifer)
    // .authenticateAs(this.username, this.passcode);
    print('EXAMPLE::Mosquitto client connecting....');
    client.connectionMessage = connMess;

    try {
      await client.connect(this.username, this.passcode);
    } on Exception catch (e) {
      print('EXAMPLE::client exception - $e');
      client.disconnect();
    }

    if (client.connectionStatus.state == MqttConnectionState.connected) {
      print('EXAMPLE::Mosquitto client connected');
      return true;
    } else {
      print(
          'EXAMPLE::ERROR Mosquitto client connection failed - disconnecting, status is ${client.connectionStatus}');
      client.disconnect();
      return false;
    }
  }

  void onConnected() {
    print('EXAMPLE::Mosquitto client connected....');
    this.client.subscribe("create_room/$roomCode", MqttQos.atLeastOnce);
    this.client.subscribe("send_to_member/$roomCode", MqttQos.atLeastOnce);
    this.client.updates.listen((List<MqttReceivedMessage<MqttMessage>> c) {
      final MqttPublishMessage recMess = c[0].payload;
      final String pt =
          MqttPublishPayload.bytesToStringAsString(recMess.payload.message);
      if (c[0].topic.toString() == "create_room/$roomCode") {
        print(
            'EXAMPLE::Change notification:: topic is ${c[0].topic}, payload is <-- $pt -->');
        setRemoteDescription(pt);
      } else if (c[0].topic.toString() == "send_to_member/$roomCode") {
        print(
            'EXAMPLE::Change notification:: topic is ${c[0].topic}, payload is <-- $pt -->');
        addCandidates(pt);
      }
    });
    print(
        'EXAMPLE::OnConnected client callback - Client connection was sucessful');
  }

  void onSubscribed(String topic) {
    print('EXAMPLE::Subscription confirmed for topic $topic');
  }

  void onDisconnected() {
    print('EXAMPLE::OnDisconnected client callback - Client disconnection');
    print(client.connectionStatus.returnCode);
    if (client.connectionStatus.disconnectionOrigin ==
        MqttDisconnectionOrigin.solicited) {
      print('EXAMPLE::OnDisconnected callback is solicited, this is correct');
    }
  }

  void publish(String topic, String message, [bool retain]) async {
    final MqttClientPayloadBuilder builder = MqttClientPayloadBuilder();
    builder.addString(message);
    client.publishMessage(topic, MqttQos.exactlyOnce, builder.payload,
        retain: retain);
  }

  _createPeerConnection() async {
    Map<String, dynamic> configuration = {
      "iceServers": [
        {
          "urls": [
            "stun:stun.l.google.com:19302",
            "stun:stun1.l.google.com:19302",
            "stun:stun2.l.google.com:19302",
            "stun:stun3.l.google.com:19302",
            "stun:stun4.l.google.com:19302"
          ]
        }
        // {
        //   "url": 'turn:numb.viagenie.ca',
        //   "credential": 'muazkh',
        //   "username": 'webrtc@live.com'
        // },
        // {
        //   "url": 'turn:192.158.29.39:3478?transport=udp',
        //   "credential": 'JZEOEt2V3Qb0y27GRntt2u2PAYA=',
        //   "username": '28224511:1379330808'
        // },
        // {
        //   "url": 'turn:192.158.29.39:3478?transport=tcp',
        //   "credential": 'JZEOEt2V3Qb0y27GRntt2u2PAYA=',
        //   "username": '28224511:1379330808'
        // },
        // {
        //   "url": 'turn:turn.bistri.com:80',
        //   "credential": 'homeo',
        //   "username": 'homeo'
        // },
        // {
        //   "url": 'turn:turn.anyfirewall.com:443?transport=tcp',
        //   "credential": 'webrtc',
        //   "username": 'webrtc'
        // }
      ]
    };

    final Map<String, dynamic> offerSdpConstraints = {
      "mandatory": {
        "OfferToReceiveAudio": true,
        "OfferToReceiveVideo": true,
      },
      "optional": [],
    };

    localStream = await getUserMedia();
    RTCPeerConnection pc =
        await createPeerConnection(configuration, offerSdpConstraints);
    pc.onIceCandidate = (event) {
      if (event.candidate != null) {
        print("candidate added");
        candidates.add(
          json.encode(
            {
              'candidate': event.candidate.toString(),
              'sdpMid': event.sdpMid.toString(),
              'sdpMlineIndex': event.sdpMlineIndex
            },
          ),
        );
      }
    };
    pc.onIceConnectionState = (RTCIceConnectionState event) {
      print("onIceConnectionState --> $event");
    };

    pc.onSignalingState = (RTCSignalingState event) {
      if (event == RTCSignalingState.RTCSignalingStateHaveRemoteOffer) {
        print("----------- remote offer has been set -------------");
        createAnswer();
      } else if (event ==
          RTCSignalingState.RTCSignalingStateHaveLocalPrAnswer) {
        print("----------- local answer has been set -------------");
      }
    };

    pc.onAddStream = (stream) {
      print('addStream: ' + stream.id);
      _remoteRenderer.srcObject = stream;
    };

    pc.onAddTrack = (MediaStream stream, MediaStreamTrack track) {
      print("-----------stream is added --------------");
      _remoteRenderer.srcObject = stream;
      _remoteRenderer.srcObject.addTrack(track);
    };

    pc.onTrack = (RTCTrackEvent event) {
      print("track is there ----------");
    };

    pc.addStream(localStream);
    _localRenderer.srcObject = localStream;

    return pc;
  }

  addCandidates(String message) {
    // var decryptedCandidate = decrypt(message);
    var allCandidates = json.decode(message);
    allCandidates.forEach((sessionCandidate) {
      dynamic session = jsonDecode(sessionCandidate);
      print(session['candidate']);
      dynamic candidate = new RTCIceCandidate(
          session['candidate'], session['sdpMid'], session['sdpMlineIndex']);
      _peerConnection.addCandidate(candidate);
    });
    // String allAnswerCandidates = encrypt(json.encode(this.candidates));
    String allAnswerCandidates = json.encode(this.candidates);
    publish("send_to_creator/$roomCode", allAnswerCandidates);
  }

  createOffer() async {
    print("--------creating offer ----------");
    RTCSessionDescription description = await _peerConnection.createOffer(
      {'offerToReceiveVideo': 1, 'offerToReceiveAudio': 1},
    );
    var session = parse(description.sdp);
    _peerConnection.setLocalDescription(description);
    // String offer = encrypt(json.encode(session));
    String offer = json.encode(session);
    publish("create_room/$roomCode", offer, true);
  }

  void createAnswer() async {
    print("--------creating answer----------");
    RTCSessionDescription description = await _peerConnection.createAnswer(
      {'offerToReceiveVideo': 1, 'offerToReceiveAudio': 1},
    );
    var session = parse(description.sdp);
    // var answer = encrypt(json.encode(session));
    var answer = json.encode(session);
    _peerConnection.setLocalDescription(description);
    publish("answer/$roomCode", answer);
  }

  void setRemoteDescription(String remoteSession) async {
    print("--------setting remote description----------");
    // var decryptedString = decrypt(remoteSession);
    dynamic session = await json.decode(remoteSession);
    String sdp = write(session, null);
    RTCSessionDescription description = new RTCSessionDescription(sdp, 'offer');
    _peerConnection.setRemoteDescription(description);
  }

  void turnOnCamera() async {
    _localRenderer.srcObject = localStream;
  }

  void turnOffCamera() {
    _localRenderer.srcObject.getVideoTracks().forEach((element) {
      element.stop();
    });
  }

  void toggleMic(bool value) {
    if (_localRenderer.srcObject != null) {
      _localRenderer.srcObject.getAudioTracks()[0].enabled =
          value ? true : false;
    }
  }

  void closeAllConnection() {
    this.client.disconnect();
    _peerConnection.close();
    _localRenderer.srcObject.getTracks().forEach((element) {
      element.stop();
    });
  }

  Future<MediaStream> getUserMedia() async {
    final Map<String, dynamic> mediaConstraints = {
      'audio': true,
      'video': {
        'facingMode': 'user',
      }
    };
    MediaStream stream =
        await navigator.mediaDevices.getUserMedia(mediaConstraints);
    return stream;
  }

  // encrypt(String rtcString) {
  //   return base64.encode(GZipEncoder().encode(utf8.encode(rtcString)));
  // }

  // decrypt(String rtcString) {
  //   return utf8.decode(GZipDecoder().decodeBytes(base64.decode(rtcString)));
  // }
}
