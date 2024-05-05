import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:fluttertoast/fluttertoast.dart';

import '../../utils/camera/coach_tts.dart';
import '../../utils/exercise.dart';
import '../../utils/camera/rep_counter.dart';
import '../../utils/camera/form_classifier.dart';
import '../../utils/camera/pose_detector.dart';
import '../../utils/camera/pose_detector_isolate.dart';

import '../../utils/workout_session.dart';
import '../../utils/camera/render_landmarks.dart';

class CameraScreen extends StatefulWidget {
  late final List<CameraDescription> cameras;
  final Exercise exercise;
  final WorkoutSession session;

  CameraScreen({
    required this.exercise,
    required this.session,
    super.key,
  });

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen>
    with WidgetsBindingObserver {
  late CameraController cameraController;
  CameraImage? cameraImage;

  /// Initializing isolate and classifier objects
  late PoseDetector classifier;
  late PoseDetectorIsolate isolate;

  /// Boolean flags for prediction and camera initialization
  bool predicting = false;
  bool initialized = false;

  late List<dynamic> inferences;
  double paddingX = 0;
  double paddingY = 0;

  /// REST MODE-RELATED FIELDS
  bool allowRestMode = false;
  bool currentlyRestingMode = false;
  late int _restSecondsRemaining;

  /// ******************************

  /// COUNTING REPS MODE-RELATED FIELDS
  late RepCounter repCounter;
  bool countingRepsMode = false;
  List<int> countingRepsInferences = [];
  int currentSetCount = 0;

  /// ******************************

  /// FormClassifier-related fields
  double formCorrectness = 0.0;
  bool showCorrectness = false;
  late FormClassifier formClassifier;

  /// ******************************

  /// FlutterTTS-related field
  CoachTTS coachTTS = CoachTTS();
  bool adviceCooldown = false;
  int currentAdvice = 0;

  /// ******************************

  void showInstructions() {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: Colors.grey[900],
          title: const Text(
            'Instructions',
            style: TextStyle(
              color: Colors.white,
            ),
          ),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: widget.exercise.cameraInstructions.length,
              itemBuilder: (context, index) {
                return ListTile(
                  title: Text(
                    "- ${widget.exercise.cameraInstructions[index]}",
                    style: const TextStyle(
                      color: Colors.white,
                    ),
                  ),
                );
              },
            ),
          ),
          actions: [
            TextButton(
              child: const Text(
                'OK',
                style: TextStyle(
                  color: Colors.white,
                ),
              ),
              onPressed: () {
                Navigator.of(context).pop();
              },
            ),
          ],
        );
      },
    );
  }

  Future<bool> _onWillPop() async {
    return (await showDialog(
          context: context,
          builder: (context) => AlertDialog(
            backgroundColor: Colors.grey[900],
            title: const Text(
              'Are you sure?',
              style: TextStyle(
                color: Colors.white,
              ),
            ),
            content: const Text(
              'Do you want to exit this screen?',
              style: TextStyle(
                color: Colors.white,
              ),
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text(
                  'Cancel',
                  style: TextStyle(
                    color: Colors.white,
                  ),
                ),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text(
                  'OK',
                  style: TextStyle(
                    color: Colors.white,
                  ),
                ),
              ),
            ],
          ),
        )) ??
        false;
  }

  @override
  void initState() {
    repCounter = RepCounter(maxRepCount: widget.session.reps);
    formClassifier =
        FormClassifier(confidenceModel: widget.exercise.formCorrectnessModel);
    _restSecondsRemaining = widget.session.restTime;

    super.initState();
    initAsync();
  }

  void initAsync() async {
    widget.cameras = await availableCameras();

    setState(() {
      cameraController = CameraController(
        widget.cameras[0], // Menggunakan kamera pertama
        ResolutionPreset.ultraHigh,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.bgra8888,
      );
    });

    isolate = PoseDetectorIsolate();
    await isolate.start();

    classifier = PoseDetector();
    classifier.loadModel();

    coachTTS.speak(
        "Welcome to AI Coach Fittness! Please read the following instructions carefully.");
    showInstructions();

    startCameraStream();
  }

  void startCameraStream() {
    cameraController.initialize().then((_) {
      if (!mounted) {
        return;
      } else {
        setState(() {
          initialized = true; // Setelah kamera diinisialisasi
        });
        cameraController.startImageStream((imageStream) {
          communicateWithIsolate(imageStream);
        });
      }
    }).catchError((e) {
      if (kDebugMode) {
        print(e);
      }
    });
  }

  void communicateWithIsolate(CameraImage imageStream) async {
    if (predicting == true) {
      return;
    }

    setState(() {
      predicting = true;
    });

    var isolateData = IsolateData(imageStream, classifier.interpreter.address);

    Map<String, List<dynamic>> inferenceResultsMap =
        await inference(isolateData);

    List<dynamic> inferenceResultsNormalised =
        inferenceResultsMap['resultsNormalised'] as List<dynamic>;
    // print(inferenceResultsNormalised);
    formClassifier.runModel(inferenceResultsNormalised);
    // print(formClassifier.outputConfidence.getDoubleList()[0]);
    formCorrectness = formClassifier.outputConfidence.getDoubleList()[0];

    List<dynamic> inferenceResults =
        inferenceResultsMap['resultsCoordinates'] as List<dynamic>;

    /*
    if (isNotMoving) {
      print("I'm not moving");
    } else {
      print("I'm moving");
    }
    */

    /// Counting reps inferences
    if (countingRepsMode &&
        inferenceResults[widget.exercise.trackedKeypoint][2] >= 0.3) {
      repCounter.startCounting(
          inferenceResults[widget.exercise.trackedKeypoint]
              [widget.exercise.trackingDirection],
          widget.exercise.fullRepPosition);
      if (repCounter.currentRepCount >= repCounter.maxRepCount) {
        countingRepsMode = false;
      }
    }

    /// Random advice during workout if form correctness < 0.5
    if (!adviceCooldown &&
        formCorrectness < 0.5 &&
        showCorrectness &&
        countingRepsMode) {
      // print("here");
      coachTTS.speak(widget.exercise.correctionAdvice[
          currentAdvice % widget.exercise.correctionAdvice.length]);
      currentAdvice++;
      adviceCooldown = true;
      Timer(const Duration(seconds: 30), () {
        adviceCooldown = false;
      });
    }

    setState(() {
      inferences = inferenceResults;
      predicting = false;
      initialized = true;
    });

    // print(inferenceResults[widget.exercise.trackedKeypoint][widget.exercise.trackingDirection]);
  }

  Future<Map<String, List<dynamic>>> inference(IsolateData isolateData) async {
    ReceivePort responsePort = ReceivePort();
    isolate.sendPort.send(isolateData..responsePort = responsePort.sendPort);
    var results = await responsePort.first;
    return results;
  }

  void startRestTimer() {
    _restSecondsRemaining = widget.session.restTime;
    Timer.periodic(const Duration(seconds: 1), (timer) {
      setState(() {
        if (_restSecondsRemaining > 0) {
          _restSecondsRemaining--;
        } else {
          coachTTS.speak("Time's up! Let's get back to work.");
          timer.cancel();
        }
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: _onWillPop,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Column(
          children: [
            Stack(
              children: [
                Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: paddingX,
                    vertical: paddingY,
                  ),
                  child: initialized
                      ? SizedBox(
                          width: cameraController.value.previewSize?.width,
                          height: cameraController.value.previewSize?.height,
                          child: CustomPaint(
                            foregroundPainter: RenderLandmarks(inferences),
                            child: CameraPreview(cameraController),
                          ),
                        )
                      : const Center(
                          child: CircularProgressIndicator(), // Indikator loading jika kamera belum siap
                        ),
                ),
                Positioned(
                  bottom: 60,
                  right: 24,
                  child: Text(
                    "$currentSetCount / ${widget.session.sets} sets",
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 32,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                Positioned(
                  bottom: 24,
                  right: 24,
                  child: Text(
                    "${repCounter.currentRepCount} / ${widget.session.reps} reps",
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 32,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                Visibility(
                  visible: showCorrectness && !currentlyRestingMode,
                  child: Positioned(
                    bottom: 24,
                    left: 24,
                    child: Text(
                      // "${(formCorrectness * 100).toStringAsFixed(2)}%",
                      formCorrectness > 0.5 ? "Correct" : "Incorrect",
                      style: TextStyle(
                        color:
                            formCorrectness > 0.5 ? Colors.green : Colors.red,
                        fontSize: 32,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(
              height: 16,
            ),

            /// Row containing buttons for user interaction
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                /// ElevatedButton for Warmup Mode
                ElevatedButton(
                  onPressed: () {
                    if (allowRestMode &&
                        (currentSetCount < widget.session.sets)) {
                      currentSetCount++;
                      coachTTS.speak(
                          "You have finished your set! Take a ${widget.session.restTime} second break and come back.");
                      if (currentSetCount < widget.session.sets) {
                        currentlyRestingMode = true;
                        startRestTimer();
                        Timer(
                          Duration(seconds: widget.session.restTime),
                          () {
                            allowRestMode = false;
                            currentlyRestingMode = false;
                            repCounter.resetRepCount();
                          },
                        );
                      } else {
                        // At this condition, the user will have finished his required sets, and completed his workout
                        coachTTS.speak(
                            "Well done! You have completed your workout! Great Job!");
                        showDialog(
                          context: context,
                          builder: (BuildContext context) {
                            return AlertDialog(
                              backgroundColor: Colors.grey[900],
                              title: const Text(
                                'Congratulations!',
                                style: TextStyle(
                                  color: Colors.white,
                                ),
                              ),
                              content: const Text(
                                'You have finished your workout.',
                                style: TextStyle(
                                  color: Colors.white,
                                ),
                              ),
                              actions: <Widget>[
                                TextButton(
                                  child: const Text(
                                    'OK',
                                    style: TextStyle(
                                      color: Colors.white,
                                    ),
                                  ),
                                  onPressed: () {
                                    Navigator.of(context).pop();
                                    Navigator.of(context).pop();
                                    Navigator.of(context).pop();
                                  },
                                ),
                              ],
                            );
                          },
                        );
                      }
                    }
                    // repCounter.resetRepCount();
                    showCorrectness = true;
                    allowRestMode = true;

                    Timer(
                      const Duration(seconds: 5),
                      () {
                        countingRepsMode = true;
                      },
                    );
                  },
                  style: ElevatedButton.styleFrom(
                    foregroundColor: Colors.white,
                    backgroundColor: Colors.green,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20.0),
                    ),
                    minimumSize: const Size(150.0, 60.0),
                    textStyle: const TextStyle(
                      fontSize: 20.0,
                    ),
                  ),
                  child: Text(allowRestMode
                      ? currentlyRestingMode
                          ? "$_restSecondsRemaining s"
                          : 'Rest'
                      : 'Start'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // App state changed before we got the chance to initialize.
    if (!cameraController.value.isInitialized) {
      return;
    }
    if (state == AppLifecycleState.inactive) {
      // Free up memory when camera not active
      cameraController.dispose();
    }
  }

  @override
  void dispose() {
    coachTTS.tts.stop();
    cameraController.dispose();
    isolate.stop();
    super.dispose();
  }
}
