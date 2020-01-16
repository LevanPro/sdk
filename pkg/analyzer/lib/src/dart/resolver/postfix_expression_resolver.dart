// Copyright (c) 2020, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/error/listener.dart';
import 'package:analyzer/src/dart/ast/ast.dart';
import 'package:analyzer/src/dart/element/type.dart';
import 'package:analyzer/src/dart/resolver/flow_analysis_visitor.dart';
import 'package:analyzer/src/dart/resolver/invocation_inference_helper.dart';
import 'package:analyzer/src/dart/resolver/resolution_result.dart';
import 'package:analyzer/src/dart/resolver/type_property_resolver.dart';
import 'package:analyzer/src/error/codes.dart';
import 'package:analyzer/src/generated/element_type_provider.dart';
import 'package:analyzer/src/generated/resolver.dart';
import 'package:analyzer/src/generated/type_system.dart';
import 'package:analyzer/src/task/strong/checker.dart';
import 'package:meta/meta.dart';

/// Helper for resolving [PostfixExpression]s.
class PostfixExpressionResolver {
  final ResolverVisitor _resolver;
  final FlowAnalysisHelper _flowAnalysis;
  final ElementTypeProvider _elementTypeProvider;
  final TypePropertyResolver _typePropertyResolver;
  final InvocationInferenceHelper _inferenceHelper;

  PostfixExpressionResolver({
    @required ResolverVisitor resolver,
    @required FlowAnalysisHelper flowAnalysis,
    @required ElementTypeProvider elementTypeProvider,
  })  : _resolver = resolver,
        _flowAnalysis = flowAnalysis,
        _elementTypeProvider = elementTypeProvider,
        _typePropertyResolver = resolver.typePropertyResolver,
        _inferenceHelper = resolver.inferenceHelper;

  ErrorReporter get _errorReporter => _resolver.errorReporter;

  bool get _isNonNullableByDefault => _typeSystem.isNonNullableByDefault;

  TypeSystemImpl get _typeSystem => _resolver.typeSystem;

  void resolve(PostfixExpressionImpl node) {
    node.operand.accept(_resolver);

    var receiverType = getReadType(
      node.operand,
      elementTypeProvider: _elementTypeProvider,
    );

    if (node.operator.type == TokenType.BANG) {
      _resolveNullCheck(node, receiverType);
      return;
    }

    _resolve1(node, receiverType);
    _resolve2(node, receiverType);
  }

  /// Check that the result [type] of a prefix or postfix `++` or `--`
  /// expression is assignable to the write type of the [operand].
  ///
  /// TODO(scheglov) this is duplicate
  void _checkForInvalidAssignmentIncDec(
      AstNode node, Expression operand, DartType type) {
    var operandWriteType = _getWriteType(operand);
    if (!_typeSystem.isAssignableTo(type, operandWriteType)) {
      _resolver.errorReporter.reportErrorForNode(
        StaticTypeWarningCode.INVALID_ASSIGNMENT,
        node,
        [type, operandWriteType],
      );
    }
  }

  /// Compute the static return type of the method or function represented by the given element.
  ///
  /// @param element the element representing the method or function invoked by the given node
  /// @return the static return type that was computed
  ///
  /// TODO(scheglov) this is duplicate
  DartType _computeStaticReturnType(Element element) {
    if (element is PropertyAccessorElement) {
      //
      // This is a function invocation expression disguised as something else.
      // We are invoking a getter and then invoking the returned function.
      //
      FunctionType propertyType =
          _elementTypeProvider.getExecutableType(element);
      if (propertyType != null) {
        return _resolver.inferenceHelper.computeInvokeReturnType(
            propertyType.returnType,
            isNullAware: false);
      }
    } else if (element is ExecutableElement) {
      return _resolver.inferenceHelper.computeInvokeReturnType(
          _elementTypeProvider.getExecutableType(element),
          isNullAware: false);
    }
    return DynamicTypeImpl.instance;
  }

  /// Return the name of the method invoked by the given postfix [expression].
  String _getPostfixOperator(PostfixExpression expression) {
    if (expression.operator.type == TokenType.PLUS_PLUS) {
      return TokenType.PLUS.lexeme;
    } else if (expression.operator.type == TokenType.MINUS_MINUS) {
      return TokenType.MINUS.lexeme;
    } else {
      throw UnsupportedError(
          'Unsupported postfix operator ${expression.operator.lexeme}');
    }
  }

  DartType _getWriteType(Expression node) {
    if (node is SimpleIdentifier) {
      var element = node.staticElement;
      if (element is PromotableElement) {
        return _elementTypeProvider.getVariableType(element);
      }
    }
    return node.staticType;
  }

  void _resolve1(PostfixExpression node, DartType receiverType) {
    Expression operand = node.operand;

    if (identical(receiverType, NeverTypeImpl.instance)) {
      _resolver.errorReporter.reportErrorForNode(
        HintCode.RECEIVER_OF_TYPE_NEVER,
        operand,
      );
      return;
    }

    String methodName = _getPostfixOperator(node);
    var result = _typePropertyResolver.resolve(
      receiver: operand,
      receiverType: receiverType,
      name: methodName,
      receiverErrorNode: operand,
      nameErrorNode: operand,
    );
    node.staticElement = result.getter;
    if (_shouldReportInvalidMember(receiverType, result)) {
      if (operand is SuperExpression) {
        _errorReporter.reportErrorForToken(
          StaticTypeWarningCode.UNDEFINED_SUPER_OPERATOR,
          node.operator,
          [methodName, receiverType],
        );
      } else {
        _errorReporter.reportErrorForToken(
          StaticTypeWarningCode.UNDEFINED_OPERATOR,
          node.operator,
          [methodName, receiverType],
        );
      }
    }
  }

  void _resolve2(PostfixExpression node, DartType receiverType) {
    Expression operand = node.operand;

    if (identical(receiverType, NeverTypeImpl.instance)) {
      _inferenceHelper.recordStaticType(node, NeverTypeImpl.instance);
    } else {
      DartType operatorReturnType;
      if (receiverType.isDartCoreInt) {
        // No need to check for `intVar++`, the result is `int`.
        operatorReturnType = receiverType;
      } else {
        var operatorElement = node.staticElement;
        operatorReturnType = _computeStaticReturnType(operatorElement);
        _checkForInvalidAssignmentIncDec(node, operand, operatorReturnType);
      }
      if (operand is SimpleIdentifier) {
        var element = operand.staticElement;
        if (element is PromotableElement) {
          _flowAnalysis?.flow?.write(element, operatorReturnType);
        }
      }
    }

    _inferenceHelper.recordStaticType(node, receiverType);
  }

  void _resolveNullCheck(PostfixExpressionImpl node, DartType operandType) {
    var type = _typeSystem.promoteToNonNull(operandType);
    _inferenceHelper.recordStaticType(node, type);

    _flowAnalysis?.flow?.nonNullAssert_end(node.operand);
  }

  /// Return `true` if we should report an error for the lookup [result] on
  /// the [type].
  ///
  /// TODO(scheglov) this is duplicate
  bool _shouldReportInvalidMember(DartType type, ResolutionResult result) {
    if (result.isNone && type != null && !type.isDynamic) {
      if (_isNonNullableByDefault && _typeSystem.isPotentiallyNullable(type)) {
        return false;
      }
      return true;
    }
    return false;
  }
}
