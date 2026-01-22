import 'dart:io';

class AppConfig {
  static get baseUrl => Platform.environment['BASE_URL'] ?? 'http://localhost';
  static final dbHost = Platform.environment['DB_HOST'] ?? 'localhost';
  static final dbPort = int.parse(Platform.environment['DB_PORT'] ?? '5432');
  static final dbName = Platform.environment['DB_NAME'] ?? 'rajasthanlimesuppliersdb';
  static final dbUser = Platform.environment['DB_USER'] ?? 'rajasthanlimesuppliers';
  static final dbPassword = Platform.environment['DB_PASSWORD'] ?? 'Rajasthan@Suppliers2002';
  static final serverPort = int.parse(Platform.environment['SERVER_PORT'] ?? '9090');
  static String uploadsDir = '';
  static const String superAdminName = 'Rajasthan Lime Suppliers';
  static const String superAdminEmail = 'info@rajasthanlimesuppliers.com';
  static const String personalEmail = 'amaan.dhanerawala372002@gmail.com';
  static const String superAdminContact = '7572877843';
  static const String secretKey = 'aa9a007810bb1b7e1e05576a08fe4250dcada3476117eb956d94e9b61fe41b0e';
  static const String appName = 'recipe';
  static const String userDetails = 'user_details';
  static const String generateOtp = 'generate_otp';
  static const String categoryDetails = 'category_details';
  static const String attributeDetails = 'attribute_details';
  static const String recipeDetails = 'recipe_details';
  static const String recipeWishlist = 'recipe_wishlist';
  static const String recipeBookmark = 'recipe_bookmark';
  static const String recipeViews = 'recipe_views';
  static const String userFollowers = 'user_followers';
  static const String cookVerificationDocuments = 'cook_verification_documents';
  static const String subscriptionPlans = 'subscription_plans';
  static const String userSubscriptions = 'user_subscriptions';
  static const String recipePricing = 'recipe_pricing';
  static const String recipePurchases = 'recipe_purchases';
  static const String monthlyRecipeMetrics = 'monthly_recipe_metrics';
  static const String monthlySubscriptionRevenue = 'monthly_subscription_revenue';
  static const String cookMonthlyEarnings = 'cook_monthly_earnings';
  static const String cookWalletTransactions = 'cook_wallet_transactions';
}
