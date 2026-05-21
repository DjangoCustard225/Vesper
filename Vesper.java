import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStreamReader;
import java.util.Scanner;

import javafx.application.Application;
import javafx.application.Platform;
import javafx.geometry.Insets;
import javafx.geometry.Pos;
import javafx.scene.Scene;
import javafx.scene.control.Button;
import javafx.scene.control.ComboBox;
import javafx.scene.control.Label;
import javafx.scene.control.TextArea;
import javafx.scene.control.TextField;
import javafx.scene.layout.HBox;
import javafx.scene.layout.VBox;
import javafx.stage.Stage;

public class Vesper extends Application {
    public static void main(String[] args) {
        launch(args);
    }

    @Override
    public void start(Stage stage) throws Exception {
       TextField tf1 = new TextField();
       tf1.setPromptText("Enter the URL");
       ComboBox<String> cb1 = new ComboBox<>();
       cb1.setPromptText("Quality");
       cb1.getItems().addAll("2160p (4K)", "1440p", "1080p (FHD)", "720p", "480p (SD)");
       TextArea ta = new TextArea();
       ta.setPadding(new Insets(10));
       Button b1 = new Button("Go");
       b1.setOnAction((e) -> {
        String url = tf1.getText().trim();
        if (url.isEmpty()) {
            ta.setText("Please enter a URL!\n");
            return;
        }
        ta.setText("Starting download...\n");
        String quality = cb1.getValue();
        new Thread(() -> {
            String flag;
            try {
                switch (quality) {
                    case "2160p (4K)": {
                        flag = "bv*[height<=2160]+ba/b";
                        break;
                    }
                    case "1440p": {
                        flag = "bv*[height<=1440]+ba/b";
                        break;
                    }
                    case "1080p (FHD)": {
                        flag = "bv*[height<=1080]+ba/b";
                        break;
                    }
                    case "720p": {
                        flag = "bv*[height<=720]+ba/b";
                        break;
                    }
                    case "480p (SD)": {
                        flag = "bv*[height<=480]+ba/b";
                        break;
                    }
                    default:
                        flag = "bv+ba/b";
                        break;

                }
                ProcessBuilder pb1 = new ProcessBuilder("yt-dlp.exe", "-f", flag, url);
                Process p1 = pb1.start();
                BufferedReader br = new BufferedReader(new InputStreamReader(p1.getInputStream()));
                Scanner scanner = new Scanner(br);
                while(scanner.hasNext()) {
                    final String line = scanner.nextLine();
                    if (line.contains("%")) {
                        Platform.runLater(() -> {
                            ta.setText(line + "\n");
                        });
                    }
                }
                scanner.close();
                int exitCode = p1.waitFor();
                if (exitCode == 0) {
                    ta.appendText("Download complete!\n");
                } else {
                    ta.appendText("Download failed!\n");
                }
            } catch (IOException | InterruptedException e1) {
                e1.printStackTrace();
            }
        }).start();
    });

       HBox h1 = new HBox();
       h1.setAlignment(Pos.TOP_CENTER);
       h1.setPadding(new Insets(10));
       h1.setSpacing(10);
       h1.getChildren().addAll(tf1, cb1, b1);
       VBox v1 = new VBox();
       v1.getChildren().addAll(h1, ta);
       Scene scene = new Scene(v1);
       stage.setScene(scene);
       stage.setTitle("Vesper");
       stage.show();

       Platform.runLater(() -> {
            h1.requestFocus();
        });
    }

}

