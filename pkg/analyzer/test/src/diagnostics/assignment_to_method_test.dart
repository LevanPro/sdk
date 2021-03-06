// Copyright (c) 2019, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analyzer/dart/analysis/features.dart';
import 'package:analyzer/src/error/codes.dart';
import 'package:analyzer/src/generated/engine.dart';
import 'package:test_reflective_loader/test_reflective_loader.dart';

import '../dart/resolution/driver_resolution.dart';

main() {
  defineReflectiveSuite(() {
    defineReflectiveTests(AssignmentToMethodTest);
    defineReflectiveTests(AssignmentToMethodWithExtensionMethodsTest);
  });
}

@reflectiveTest
class AssignmentToMethodTest extends DriverResolutionTest {
  test_method() async {
    await assertErrorsInCode('''
class A {
  m() {}
}
f(A a) {
  a.m = () {};
}''', [
      error(StaticWarningCode.ASSIGNMENT_TO_METHOD, 32, 3),
    ]);
  }
}

@reflectiveTest
class AssignmentToMethodWithExtensionMethodsTest
    extends AssignmentToMethodTest {
  @override
  AnalysisOptionsImpl get analysisOptions => AnalysisOptionsImpl()
    ..contextFeatures = FeatureSet.forTesting(
        sdkVersion: '2.3.0', additionalFeatures: [Feature.extension_methods]);

  test_instance_extendedHasMethod_extensionHasSetter() async {
    await assertErrorsInCode('''
class C {
  void foo() {}
}

extension E on C {
  void set foo(int _) {}
}

f(C c) {
  c.foo = 0;
}
''', [
      error(StaticWarningCode.ASSIGNMENT_TO_METHOD, 87, 5),
      error(StaticTypeWarningCode.INVALID_ASSIGNMENT, 95, 1),
    ]);
  }

  test_this_extendedHasMethod_extensionHasSetter() async {
    await assertErrorsInCode('''
class C {
  void foo() {}
}

extension E on C {
  void set foo(int _) {}

  f() {
    this.foo = 0;
  }
}
''', [
      error(StaticWarningCode.ASSIGNMENT_TO_METHOD, 86, 8),
      error(StaticTypeWarningCode.INVALID_ASSIGNMENT, 97, 1),
    ]);
  }
}
