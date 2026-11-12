import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:GMS/core/widgets/gms_header.dart';
import 'package:GMS/core/services/refresh_bus.dart';
import 'package:GMS/core/utils/time_format.dart' show parseServerTime;

class PaymentsScreen extends StatefulWidget {
  const PaymentsScreen({super.key});

  @override
  State<PaymentsScreen> createState() => _PaymentsScreenState();
}

class _PaymentsScreenState extends State<PaymentsScreen>
    with TickerProviderStateMixin {
  // ================================================================
  // STORED VALUES
  // ================================================================
  String upiId = "mkrathish221311@oksbi";

  String cardNumber = "4532160720061819"; // stored as digits only
  bool cardVisible = false;
  bool cardExpanded = false;
  String cardType = "Unknown"; // 🔥 NEW
  String cardUpdatedAt = "";

  // ================================================================
  // PRETTY DATE
  // ================================================================
  String prettyDate(String isoString) {
    if (isoString.isEmpty) return "Not updated yet";

    final d = parseServerTime(isoString);
    if (d == null) return "Not updated yet";
    DateTime now = DateTime.now();
    Duration diff = now.difference(d);

    if (diff.inSeconds < 60) return "Just now";
    if (diff.inMinutes < 60) return "${diff.inMinutes} minutes ago";
    if (diff.inHours < 24) return "${diff.inHours} hours ago";
    if (diff.inDays == 0) return "Today, ${_formatTime(d)}";
    if (diff.inDays == 1) return "Yesterday, ${_formatTime(d)}";

    return "${d.day} ${_monthName(d.month)} ${d.year}, ${_formatTime(d)}";
  }

  String _formatTime(DateTime dt) {
    int hour = dt.hour;
    int minute = dt.minute;
    String m = minute.toString().padLeft(2, '0');

    String period = hour >= 12 ? "PM" : "AM";

    if (hour > 12) hour -= 12;
    if (hour == 0) hour = 12;

    return "$hour:$m $period";
  }

  String _monthName(int m) {
    const arr = [
      "",
      "Jan",
      "Feb",
      "Mar",
      "Apr",
      "May",
      "Jun",
      "Jul",
      "Aug",
      "Sep",
      "Oct",
      "Nov",
      "Dec",
    ];
    return arr[m];
  }

  // ================================================================
  // INIT
  // ================================================================
  @override
  void initState() {
    super.initState();
    _loadUpiId();
    _loadCardNumber();
    RefreshBus.payments.addListener(_onRefreshBusPayments);
  }

  void _onRefreshBusPayments() {
    if (!mounted) return;
    _loadUpiId();
    _loadCardNumber();
  }

  @override
  void dispose() {
    RefreshBus.payments.removeListener(_onRefreshBusPayments);
    super.dispose();
  }

  Future<void> _loadUpiId() async {
    final prefs = await SharedPreferences.getInstance();
    upiId = prefs.getString("upi_id") ?? upiId;
    setState(() {});
  }

  Future<void> _saveUpiId(String newUpi) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString("upi_id", newUpi);
  }

  Future<void> _loadCardNumber() async {
    final prefs = await SharedPreferences.getInstance();
    cardNumber = prefs.getString("card_number") ?? cardNumber;
    cardUpdatedAt = prefs.getString("card_updated_date") ?? "";
    setState(() {
      cardNumber = prefs.getString("card_number") ?? cardNumber;
      cardUpdatedAt = prefs.getString("card_updated_date") ?? "";
      cardType =
          prefs.getString("card_type") ?? detectCardType(cardNumber); // 🔥 NEW
    });
  }

  Future<void> _saveCardNumber(String number) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString("card_number", number.replaceAll(" ", ""));
    await prefs.setString(
      "card_updated_date",
      DateTime.now().toIso8601String(),
    );
  }

  // ================================================================
  // CARD HELPERS
  // ================================================================
  String maskedCard() {
    if (cardNumber.length < 4) return "**** **** **** ****";
    return "**** **** **** ${cardNumber.substring(cardNumber.length - 4)}";
  }

  String formatCard(String input) {
    final clean = input.replaceAll(" ", "");
    final buffer = StringBuffer();

    for (int i = 0; i < clean.length; i++) {
      buffer.write(clean[i]);
      if ((i + 1) % 4 == 0 && i != clean.length - 1) {
        buffer.write(" ");
      }
    }
    return buffer.toString();
  }

  String detectCardType(String number) {
    number = number.replaceAll(" ", "");
    if (number.startsWith("4")) return "VISA";
    if (number.startsWith("5")) return "MasterCard";
    if (number.startsWith("34") || number.startsWith("37")) return "AMEX";
    if (number.startsWith("6")) return "RuPay";
    return "Unknown";
  }

  // ================================================================
  // UI BUILD
  // ================================================================
  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        GMSHeader(parentContext: context),
        const SizedBox(height: 16),
        _walletCard(),
        const SizedBox(height: 16),
        _paymentMethods(context),
        const SizedBox(height: 16),
        _transactionHistory(),
      ],
    );
  }

  // ================================================================
  // WALLET UI
  // ================================================================
  Widget _walletCard() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.blue[700],
        borderRadius: BorderRadius.circular(15),
      ),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Wallet Balance', style: TextStyle(color: Colors.white70)),
          SizedBox(height: 5),
          Text(
            '₹18,190.50',
            style: TextStyle(
              color: Colors.white,
              fontSize: 28,
              fontWeight: FontWeight.bold,
            ),
          ),
          SizedBox(height: 10),
          ElevatedButton(onPressed: null, child: Text('Add Money')),
        ],
      ),
    );
  }

  // ================================================================
  // PAYMENT METHODS
  // ================================================================
  Widget _paymentMethods(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Payment Methods',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),

        // CARD TILE (EXPANDABLE)
        AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
          child: Card(
            child: InkWell(
              onTap: () => setState(() => cardExpanded = !cardExpanded),
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.credit_card),
                    title: const Text('Credit/Debit Card'),
                    subtitle: Text(
                      cardVisible ? formatCard(cardNumber) : maskedCard(),
                      style: const TextStyle(fontSize: 15),
                    ),
                    trailing: cardExpanded
                        ? Wrap(
                            children: [
                              IconButton(
                                icon: Icon(
                                  cardVisible
                                      ? Icons.visibility_off
                                      : Icons.visibility,
                                ),
                                onPressed: () =>
                                    setState(() => cardVisible = !cardVisible),
                              ),
                              IconButton(
                                icon: const Icon(Icons.edit),
                                onPressed: () => _editCardDialog(context),
                              ),
                            ],
                          )
                        : null,
                  ),

                  if (cardExpanded)
                    Padding(
                      padding: const EdgeInsets.only(
                        left: 16,
                        right: 16,
                        bottom: 16,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Divider(),
                          const SizedBox(height: 8),
                          Text(
                            "Card Type: $cardType",
                            style: const TextStyle(fontSize: 14),
                          ),
                          Text(
                            "Last Updated: ${prettyDate(cardUpdatedAt)}",
                            style: const TextStyle(
                              fontSize: 13,
                              color: Colors.grey,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),

        const SizedBox(height: 10),

        // UPI TILE
        Card(
          child: ListTile(
            leading: const Icon(Icons.account_balance_wallet_outlined),
            title: const Text('UPI'),
            subtitle: Text(upiId),
            trailing: IconButton(
              icon: const Icon(Icons.edit),
              onPressed: () => _editUpiDialog(context),
            ),
          ),
        ),
      ],
    );
  }

  // ================================================================
  // CARD UPDATE DIALOG (NO LUHN)
  // ================================================================
  void _editCardDialog(BuildContext context) async {
    final prefs = await SharedPreferences.getInstance();

    final controller = TextEditingController(text: formatCard(cardNumber));

    final cardRegex = RegExp(r'^[0-9 ]+$');

    String errorText = "";
    bool showError = false;

    // Animations
    final shakeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );

    final successController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );

    final underlineController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    )..repeat(reverse: true);

    final shakeAnimation = Tween(
      begin: 0.0,
      end: 12.0,
    ).chain(CurveTween(curve: Curves.elasticIn)).animate(shakeController);

    List<String> recentCards = prefs.getStringList("recent_card_list") ?? [];

    Future<void> saveRecent(String card) async {
      if (!recentCards.contains(card)) {
        recentCards.insert(0, card);
        if (recentCards.length > 5) recentCards.removeLast();
        await prefs.setStringList("recent_card_list", recentCards);
      }
    }

    Future<void> validateSave() async {
      String input = controller.text.trim();
      input = formatCard(input);

      // ONLY check: numbers only
      if (!cardRegex.hasMatch(input.replaceAll(" ", ""))) {
        shakeController.forward().then((_) => shakeController.reverse());
        errorText = "Only digits allowed";
        showError = true;
        (context as Element).markNeedsBuild();
        Future.delayed(
          const Duration(seconds: 5),
          () => (context as Element).markNeedsBuild(),
        );
        return;
      }

      // MIN & MAX digits (WITHOUT Luhn)
      String digits = input.replaceAll(" ", "");
      // Card length: MUST be between 13 and 19 digits
      if (digits.length < 13 || digits.length > 19) {
        shakeController.forward().then((_) => shakeController.reverse());
        errorText = "Card number must be 13–19 digits";
        showError = true;
        (context as Element).markNeedsBuild();
        Future.delayed(
          const Duration(seconds: 5),
          () => (context as Element).markNeedsBuild(),
        );
        return;
      }

      await successController.forward();

      await _saveCardNumber(input);
      await saveRecent(input);
      await prefs.setString("card_type", cardType); // 🔥 Save selected type
      setState(() {
        cardNumber = input.replaceAll(" ", "");
        cardUpdatedAt = DateTime.now().toIso8601String();
      });

      Navigator.pop(context);

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Card number updated successfully!"),
          duration: Duration(seconds: 2),
        ),
      );
    }

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState2) => AnimatedBuilder(
          animation: shakeAnimation,
          builder: (context, child) => Transform.translate(
            offset: Offset(shakeAnimation.value, 0),
            child: AlertDialog(
              title: const Text("Update Card Number"),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Stack(
                    alignment: Alignment.center,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          TextField(
                            controller: controller,
                            autofocus: true,
                            maxLength: 23,
                            keyboardType: TextInputType.number,
                            buildCounter:
                                (
                                  context, {
                                  required int currentLength,
                                  required int? maxLength,
                                  required bool isFocused,
                                }) => null, // 🔥 removes "18/23"
                            decoration: InputDecoration(
                              labelText: "Enter Card Number",
                              enabledBorder: UnderlineInputBorder(
                                borderSide: BorderSide(
                                  color: showError
                                      ? Colors.red.withOpacity(
                                          0.4 + underlineController.value * 0.6,
                                        )
                                      : Colors.grey,
                                ),
                              ),
                            ),
                            onChanged: (value) {
                              final formatted = formatCard(value);
                              controller.value = TextEditingValue(
                                text: formatted,
                                selection: TextSelection.collapsed(
                                  offset: formatted.length,
                                ),
                              );
                            },
                            onSubmitted: (_) => validateSave(),
                          ),

                          if (showError)
                            Text(
                              errorText,
                              style: const TextStyle(
                                color: Colors.red,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),

                          const SizedBox(height: 15),

                          DropdownButtonFormField<String>(
                            value: cardType, // 🔥 uses stored type
                            decoration: const InputDecoration(
                              labelText: "Select Card Type",
                            ),
                            items: const [
                              DropdownMenuItem(
                                value: "VISA",
                                child: Text("VISA"),
                              ),
                              DropdownMenuItem(
                                value: "MasterCard",
                                child: Text("MasterCard"),
                              ),
                              DropdownMenuItem(
                                value: "AMEX",
                                child: Text("AMEX"),
                              ),
                              DropdownMenuItem(
                                value: "RuPay",
                                child: Text("RuPay"),
                              ),
                              DropdownMenuItem(
                                value: "Unknown",
                                child: Text("Unknown"),
                              ),
                            ],
                            onChanged: (value) {
                              setState2(() {
                                cardType = value!;
                              });
                            },
                          ),

                          if (recentCards.isNotEmpty) ...[
                            const SizedBox(height: 10),
                            const Text(
                              "Recent Cards",
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            ...recentCards.map(
                              (c) => ListTile(
                                dense: true,
                                title: Text(c),
                                onTap: () {
                                  controller.text = c;
                                  controller.selection =
                                      TextSelection.collapsed(offset: c.length);
                                },
                              ),
                            ),
                          ],
                        ],
                      ),

                      ScaleTransition(
                        scale: CurvedAnimation(
                          parent: successController,
                          curve: Curves.easeOutBack,
                        ),
                        child: const Icon(
                          Icons.check_circle,
                          size: 50,
                          color: Colors.green,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text("Cancel"),
                ),
                ElevatedButton(
                  onPressed: validateSave,
                  child: const Text("Save"),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ================================================================
  // UPI DIALOG (UNCHANGED)
  // ================================================================
  void _editUpiDialog(BuildContext context) async {
    final prefs = await SharedPreferences.getInstance();
    List<String> recentUpis = prefs.getStringList("recent_upi_list") ?? [];

    final controller = TextEditingController(text: upiId);
    final upiRegex = RegExp(r'^[\w.\-]{3,}@[\w]{3,}$');

    String errorText = "";
    bool showError = false;

    final shakeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );

    final successController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );

    final underlineController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    )..repeat(reverse: true);

    final shakeAnimation = Tween(
      begin: 0.0,
      end: 12.0,
    ).chain(CurveTween(curve: Curves.elasticIn)).animate(shakeController);

    String? autoCorrect(String input) {
      input = input.trim();
      if (input.contains(".com")) return input.replaceAll(".com", "");
      if (!input.contains("@") && input.length > 3) return "$input@oksbi";
      return null;
    }

    Future<void> saveRecent(String upi) async {
      if (!recentUpis.contains(upi)) {
        recentUpis.insert(0, upi);
        if (recentUpis.length > 5) recentUpis.removeLast();
        await prefs.setStringList("recent_upi_list", recentUpis);
      }
    }

    Future<void> validateSave() async {
      String input = controller.text.trim();
      final suggestion = autoCorrect(input);

      if (suggestion != null && !upiRegex.hasMatch(input)) {
        controller.text = suggestion;
        controller.selection = TextSelection.collapsed(
          offset: suggestion.length,
        );
        return;
      }

      if (!upiRegex.hasMatch(input)) {
        shakeController.forward().then((_) => shakeController.reverse());
        errorText = "Invalid UPI ID — Example: name@bank";
        showError = true;
        (context as Element).markNeedsBuild();
        Future.delayed(
          const Duration(seconds: 5),
          () => (context as Element).markNeedsBuild(),
        );
        return;
      }

      await successController.forward();

      setState(() => upiId = input);
      await _saveUpiId(input);
      await saveRecent(input);

      Navigator.pop(context);

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("UPI updated successfully!"),
          duration: Duration(seconds: 2),
        ),
      );
    }

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState2) => AnimatedBuilder(
          animation: shakeAnimation,
          builder: (context, child) => Transform.translate(
            offset: Offset(shakeAnimation.value, 0),
            child: AlertDialog(
              title: const Text("Update UPI ID"),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Stack(
                    alignment: Alignment.center,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          TextField(
                            controller: controller,
                            autofocus: true,
                            decoration: InputDecoration(
                              labelText: "Enter new UPI ID",
                              enabledBorder: UnderlineInputBorder(
                                borderSide: BorderSide(
                                  color: showError
                                      ? Colors.red.withOpacity(
                                          0.4 + underlineController.value * 0.6,
                                        )
                                      : Colors.grey,
                                ),
                              ),
                            ),
                            onSubmitted: (_) => validateSave(),
                          ),
                          const SizedBox(height: 6),

                          if (showError)
                            Text(
                              errorText,
                              style: const TextStyle(
                                color: Colors.red,
                                fontWeight: FontWeight.w600,
                                fontSize: 13,
                              ),
                            ),

                          if (recentUpis.isNotEmpty) ...[
                            const SizedBox(height: 10),
                            const Text(
                              "Recent UPI IDs",
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            ...recentUpis.map(
                              (upi) => ListTile(
                                dense: true,
                                title: Text(upi),
                                onTap: () {
                                  controller.text = upi;
                                  controller.selection =
                                      TextSelection.collapsed(
                                        offset: upi.length,
                                      );
                                },
                              ),
                            ),
                          ],
                        ],
                      ),

                      ScaleTransition(
                        scale: CurvedAnimation(
                          parent: successController,
                          curve: Curves.easeOutBack,
                        ),
                        child: const Icon(
                          Icons.check_circle,
                          size: 50,
                          color: Colors.green,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text("Cancel"),
                ),
                ElevatedButton(
                  onPressed: validateSave,
                  child: const Text("Save"),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ================================================================
  // TRANSACTIONS
  // ================================================================
  Widget _transactionHistory() {
    final transactions = [
      {
        'title': 'Electrical Services - Navaneth Sri',
        'amount': '-₹700',
        'method': 'UPI',
      },
      {
        'title': 'Master Plumbing - Siddharth',
        'amount': '-₹600',
        'method': 'Card',
      },
      {
        'title': 'Refund - Cancelled Booking',
        'amount': '+₹400',
        'method': 'Wallet',
      },
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Transaction History',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        ...transactions.map(
          (t) => Card(
            child: ListTile(
              title: Text(t['title']!),
              subtitle: Text(t['method']!),
              trailing: Text(
                t['amount']!,
                style: TextStyle(
                  color: t['amount']!.contains('+') ? Colors.green : Colors.red,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
