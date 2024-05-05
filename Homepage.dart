import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:cameraproject/home_view_screen.dart';


class welcome extends StatelessWidget {
  const welcome({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: BoxDecoration(
          color: const Color(0xff171533),
        ),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Image.asset('assets/images/logo.png', width: 180,),
              const SizedBox(height: 20),
              Text(
                'AI Coach Fitness',
                style: GoogleFonts.poppins(
                  fontSize: 24,
                  color: Colors.white,
                ),  
              ),
              const SizedBox(height: 100),
              // Kotak putih sebagai pembungkus tombol navigasi
              Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: TextButton(
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (context) => HomeViewScreen()),
                    );
                  },
                  child: Text(
                'Get Started',
                style: GoogleFonts.poppins(
                  fontSize: 24,
                  color: Color(0xff171533),
                ),  
              ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
