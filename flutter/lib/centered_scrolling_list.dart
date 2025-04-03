import 'package:flutter/material.dart';

class CenteredScrollingList extends StatelessWidget {
  final List<Map<String, dynamic>> contacts;
  final Function(int) onDelete;
  final Function(int) onEdit;
  final bool editMode;

  const CenteredScrollingList({
    super.key,
    required this.contacts,
    required this.onDelete,
    required this.onEdit,
    required this.editMode,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        children: contacts.asMap().entries.map((entry) {
          int index = entry.key;
          Map<String, dynamic> contact = entry.value;

          return Container(
            margin: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 16.0),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.13), // Transparent white
              borderRadius: BorderRadius.circular(20.0), // Rounded corners
            ),
            child: ListTile(
              title: Text(contact['contact_name'] ?? 'N/A', style: TextStyle(color:Color.fromARGB(255, 255, 255, 255))),
              subtitle: Text(contact['phone_no'] ?? 'N/A', style: TextStyle(color:Color.fromARGB(255, 163, 163, 163))),
              trailing: editMode
                  ? Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.edit, color: Color.fromARGB(255, 255, 255, 255)),
                          onPressed: () => onEdit(index),
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete, color: Color.fromARGB(255, 255, 255, 255)),
                          onPressed: () => onDelete(index),
                        ),
                      ],
                    )
                  : null,
            ),
          );
        }).toList(),
      ),
    );
  }
}